/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* HTTP/1.1 client and server, for `http` and `https`.

   ```
   import std/async
   import std/async/os/net
   import std/async/os/http

   fun main()
     val server = tcp-listen("127.0.0.1", 8080)
     http-serve(server) fn(req)
       match req.path
         "/hello" -> text-response(200, "hello " ++ req.query-param("name").default("world"))
         _        -> text-response(404, "not found")
   ```

   and as a client:

   ```
   val res = http-get("http://127.0.0.1:8080/hello?name=koka")
   println((res.status, res.body-text))
   ```

   For `https`, give the server a TLS configuration:
   `http-serve(server, handler, tls = Just(tls-server-config(cert, key)))`.

   The plain client functions open a new connection for each request. To
   reuse connections (keep-alive), make requests through an `:http-client`:

   ```
   with client = http-client()
   val a = client.http-get("http://127.0.0.1:8080/hello")
   val b = client.http-get("http://127.0.0.1:8080/hello?name=again")   // same connection
   ```

   Idle connections are closed after a while on both sides: see the
   `idle-timeout` parameters of `http-client` and `http-serve`.

   Bodies are framed with `Content-Length`, `Transfer-Encoding: chunked`, or
   (for responses) by the server closing the connection. The server supports
   persistent (keep-alive) connections. The client follows redirects.
*/
module async/os/http

import std/core/undiv
import std/core/unsafe
import std/time/duration
import std/time/timer
import async/async
import async/internal
import async/interleave
import async/channel
import async/os/net
import async/os/tls
import async/os/http2
import std/net/url
import std/text/encoding
import std/compress

// ----------------------------------------------------------------------------
// Messages
// ----------------------------------------------------------------------------

// An HTTP header list; names are matched case-insensitively.
pub alias headers = list<(string, string)>

// An HTTP request.
pub struct http-request
  method : string = "GET"
  target : string = "/"        // the request target: path and query, e.g. `/search?q=koka`
  headers : headers = []
  body : bytes = bytes/empty
  peer : string = ""           // on the server: the address of the client as `ip:port`
  client-cert : string = ""    // on the server: the subject of the client certificate (`https` with `client-ca`), if any
  version : string = "HTTP/1.1" // on the server: the protocol of the request (`"HTTP/1.1"` or `"HTTP/2"`)

// An HTTP response.
pub struct http-response
  status : int = 200
  reason : string = ""
  headers : headers = []
  body : bytes = bytes/empty
  version : string = "HTTP/1.1"   // on the client: the protocol of the response (`"HTTP/1.1"` or `"HTTP/2"`)
  body-writer : maybe<body-writer> = Nothing   // on the server: produce the body in parts (see `stream-response`)

// A function that produces a response body in parts: it calls `write` with
// each part as it becomes available. (It may diverge, as when it copies a
// stream.)
pub alias body-writer = (write : bytes -> <async,exn> ()) -> <async,exn,ndet,div> ()

// A response whose body is produced in parts by `writer`, and sent as it is
// produced (with chunked transfer encoding over HTTP/1.1, as DATA frames over
// HTTP/2; HTTP/1.0 responses collect the parts first).
//
// ```
// stream-response(200, "text/plain") fn(write)
//   for(1, 10) fn(i)
//     write(("line " ++ i.show ++ "\n").bytes)
//     wait(100.milli-seconds)
// ```
pub fun stream-response( status : int, content-type : string, writer : body-writer, headers : headers = [] ) : http-response
  Http-response(status, reason-phrase(status), headers.set-header("Content-Type", content-type), bytes/empty, "HTTP/1.1", Just(writer))

// Send a response (streamed in chunks if it has a body writer, the method is
// not HEAD, and the client speaks HTTP/1.1).
fun send-response( sock : net-stream, method : string, version : string, status-line : string, hs : headers, res : http-response ) : <async,exn,ndet> ()
  match res.body-writer
    Nothing -> write-message(sock, status-line, hs, if method == "HEAD" then bytes/empty else res.body)
    Just(w) ->
      if method == "HEAD" then write-message(sock, status-line, hs, bytes/empty)
      elif version == "HTTP/1.1" then send-chunked(sock, status-line, hs, w)
      else
        val body = collect-body(w)
        write-message(sock, status-line, hs, body)

// Send a response whose body is produced by `w`, in chunks as it is produced.
fun send-chunked( sock : net-stream, status-line : string, hs : headers, w : body-writer ) : <async,exn,ndet> ()
  val hsc = hs.remove-headers(["Content-Length"]).set-header("Transfer-Encoding", "chunked")
  sock.write-all(head-text(status-line, hsc).bytes)
  pretend-no-div { w(fn(part) send-chunk(sock, part)) }
  sock.write-all("0\r\n\r\n".bytes)

fun send-chunk( sock : net-stream, part : bytes ) : <async,exn> ()
  if !part.is-empty then
    sock.write-all((part.length.show-hex(use-capitals = False, pre = "") ++ "\r\n").bytes ++ part ++ "\r\n".bytes)

// Run a body writer and collect its parts.
fun collect-body( w : body-writer ) : <async,exn,ndet> bytes
  val parts : ref<global,list<bytes>> = async-ioc { ref([]) }
  pretend-no-div { w(fn(b) async-ioc { parts := Cons(b, read-parts(parts)) }) }
  async-ioc { read-parts(parts) }.reverse.join

fun read-parts( r : ref<global,list<bytes>> ) : <read<global>,div> list<bytes>
  !r

// Look up a header (case-insensitive).
pub fun header( hs : headers, name : string ) : maybe<string>
  val lname = name.to-lower
  hs.lookup(fn(n) n.to-lower == lname)

// Set a header, replacing any existing header with the same name.
pub fun set-header( hs : headers, name : string, value : string ) : headers
  val lname = name.to-lower
  hs.filter(fn((n, _)) n.to-lower != lname) ++ [(name, value)]

pub fun http-request/header( r : http-request, name : string ) : maybe<string>
  r.headers.header(name)

pub fun http-response/header( r : http-response, name : string ) : maybe<string>
  r.headers.header(name)

// The path part of the request target (without the query).
pub fun path( r : http-request ) : string
  match r.target.find("?")
    Just(sl) -> sl.before.string
    Nothing -> r.target

// The decoded query parameters of the request target.
pub fun http-request/query-params( r : http-request ) : list<(string, string)>
  match r.target.find("?")
    Just(sl) -> parse-query(sl.after.string)
    Nothing -> []

// Look up a (decoded) query parameter.
pub fun http-request/query-param( r : http-request, name : string ) : maybe<string>
  r.query-params.lookup(fn(k) k == name)

pub fun http-request/body-text( r : http-request ) : string
  r.body.string

pub fun http-response/body-text( r : http-response ) : string
  r.body.string

// The standard reason phrase for a status code.
pub fun reason-phrase( status : int ) : string
  match status
    100 -> "Continue"
    200 -> "OK"
    201 -> "Created"
    202 -> "Accepted"
    204 -> "No Content"
    301 -> "Moved Permanently"
    302 -> "Found"
    303 -> "See Other"
    304 -> "Not Modified"
    307 -> "Temporary Redirect"
    308 -> "Permanent Redirect"
    400 -> "Bad Request"
    401 -> "Unauthorized"
    403 -> "Forbidden"
    404 -> "Not Found"
    405 -> "Method Not Allowed"
    408 -> "Request Timeout"
    409 -> "Conflict"
    413 -> "Content Too Large"
    415 -> "Unsupported Media Type"
    429 -> "Too Many Requests"
    500 -> "Internal Server Error"
    501 -> "Not Implemented"
    502 -> "Bad Gateway"
    503 -> "Service Unavailable"
    _ -> "Unknown"

// A plain text response.
pub fun text-response( status : int, text : string, headers : headers = [] ) : http-response
  Http-response(status, reason-phrase(status), headers.set-header("Content-Type", "text/plain; charset=utf-8"), text.bytes)

// A response with a given content type.
pub fun bytes-response( status : int, body : bytes, content-type : string, headers : headers = [] ) : http-response
  Http-response(status, reason-phrase(status), headers.set-header("Content-Type", content-type), body)

// ----------------------------------------------------------------------------
// Buffered reading
// ----------------------------------------------------------------------------

// A socket with not-yet-consumed input.
value struct reader
  sock : net-stream
  buf : bytes

fun byte-at( b : bytes, i : int ) : int
  b.unsafe-index(i.ssize_t).int

// Find the first occurrence of `pat` in `b` starting at `from`.
fun bytes-find( b : bytes, pat : list<int>, from : int ) : maybe<int>
  val n = b.length
  val m = pat.length
  fun matches-at( i : int, ps : list<int>, j : int ) : bool
    match ps
      Cons(p, pp) -> b.byte-at(i + j) == p && matches-at(i, pp, j + 1)
      Nil -> True
  fun search( i : int ) : maybe<int>
    if i + m > n then Nothing
    elif matches-at(i, pat, 0) then Just(i)
    else search(pretend-decreasing(i + 1))
  search(from)

// Read more data; `False` on end-of-stream.
fun fill( r : reader ) : <async,exn> (bool, reader)
  val more = r.sock.read
  if more.is-empty then (False, r) else (True, Reader(r.sock, r.buf ++ more))

// Read up to (and consuming) the delimiter `pat`; `Nothing` on end-of-stream before the delimiter.
fun read-until( r : reader, pat : list<int>, max-len : int ) : <async,exn> maybe<(bytes, reader)>
  fun go( r0 : reader, from : int ) : <async,exn> maybe<(bytes, reader)>
    match bytes-find(r0.buf, pat, from)
      Just(i) -> Just((r0.buf.subbytes(0, i), Reader(r0.sock, r0.buf.subbytes(i + pat.length))))
      Nothing ->
        if r0.buf.length > max-len then throw("http: header section too large")
        val (ok, r1) = r0.fill
        if !ok then Nothing
        else go(pretend-decreasing(r1), max(0, r0.buf.length - pat.length))
  go(r, 0)

// Read exactly `n` bytes.
fun read-exact( r : reader, n : int ) : <async,exn> (bytes, reader)
  if r.buf.length >= n then (r.buf.subbytes(0, n), Reader(r.sock, r.buf.subbytes(n)))
  else
    val (ok, r1) = r.fill
    if !ok then throw("http: connection closed in the middle of a message body")
    read-exact(pretend-decreasing(r1), n)

// Read until the end of the stream.
fun read-to-eof( r : reader ) : <async,exn> bytes
  val (ok, r1) = r.fill
  if ok then read-to-eof(pretend-decreasing(r1)) else r.buf

val crlf = [13, 10]
val crlfcrlf = [13, 10, 13, 10]

// Read a chunked body (RFC 9112 section 7.1); trailers are ignored.
fun read-chunked( r : reader, acc : list<bytes> ) : <async,exn> (bytes, reader)
  match r.read-until(crlf, 1024)
    Nothing -> throw("http: connection closed in a chunked body")
    Just((line, r1)) ->
      val size-text = line.string.split(";").head.default("").trim
      val size = match parse-int(size-text, hex = True)
        Just(n) -> n
        Nothing -> throw("http: invalid chunk size " ++ size-text.show)
      if size == 0 then
        // skip optional trailers up to the empty line
        val r2 = skip-trailers(r1)
        (acc.reverse.join, r2)
      else
        val (chunk, r2) = r1.read-exact(size)
        val (_, r3) = r2.read-exact(2)   // CRLF after the chunk
        read-chunked(pretend-decreasing(r3), Cons(chunk, acc))

fun skip-trailers( r : reader ) : <async,exn> reader
  match r.read-until(crlf, 8192)
    Just((line, r1)) -> if line.is-empty then r1 else skip-trailers(pretend-decreasing(r1))
    Nothing -> r

// Parse the header lines (after the start line).
fun parse-headers( lines : list<string> ) : exn headers
  lines.filter(fn(l) !l.is-empty).map fn(l)
    match l.find(":")
      Just(sl) -> (sl.before.string.trim, sl.after.string.trim)
      Nothing -> throw("http: invalid header line " ++ l.show)

// Read the body framed by the headers. `until-eof` reads to the end of the
// stream when there is no length (responses only).
fun read-body( r : reader, hs : headers, until-eof : bool ) : <async,exn> (bytes, reader)
  val te = hs.header("Transfer-Encoding").default("").to-lower
  if te.find("chunked").is-just then r.read-chunked([])
  else match hs.header("Content-Length")
    Just(cl) -> match parse-int(cl.trim)
      Just(n) | n >= 0 -> r.read-exact(n)
      _ -> throw("http: invalid Content-Length " ++ cl.show)
    Nothing ->
      if until-eof then (r.read-to-eof, Reader(r.sock, bytes/empty))
      else (bytes/empty, r)

// ----------------------------------------------------------------------------
// Writing
// ----------------------------------------------------------------------------

fun head-text( start-line : string, hs : headers ) : string
  start-line ++ "\r\n" ++ hs.map(fn((n, v)) n ++ ": " ++ v ++ "\r\n").join ++ "\r\n"

fun write-message( s : net-stream, start-line : string, hs : headers, body : bytes ) : <async,exn> ()
  val hs' = if hs.header("Content-Length").is-just || hs.header("Transfer-Encoding").is-just then hs
            else hs.set-header("Content-Length", body.length.show)
  s.write-all(head-text(start-line, hs').bytes ++ body)

// ----------------------------------------------------------------------------
// Client
// ----------------------------------------------------------------------------

// Send an HTTP request to `url` and return the response. A new connection is
// used for each request; see `:http-client` to reuse connections.
//
// Redirects (`301`, `302`, `303`, `307`, `308`) are followed up to
// `max-redirects` times, after which an exception is raised. With
// `max-redirects = 0` the redirect response itself is returned. As in
// browsers, a `303` (or a `301`/`302` after a `POST`) is followed with a `GET`
// without a body, while `307` and `308` repeat the original method and body.
// The `Authorization` and `Cookie` headers are dropped when a redirect leads
// to a different origin.
//
// Unless `headers` contain an `Accept-Encoding`, the request asks for gzip or
// deflate compressed responses and the body is decompressed (the
// `Content-Encoding` header is then removed). With an explicit
// `Accept-Encoding`, the body is returned as it was sent.
//
// For `https`, the server certificate is checked against the system CA
// certificates, or only against `tls-ca` (PEM certificates) if it is given,
// and it is rejected if a certificate revocation list in `tls-crl` (PEM) revokes it.
// A client certificate (`tls-cert`, PEM) and its private key (`tls-key`) are
// presented to servers that ask for one.
pub fun http-request( method : string, url : string, headers : headers = [], body : bytes = bytes/empty, max-redirects : int = 10,
                      tls-ca : string = "", tls-cert : string = "", tls-key : string = "", tls-crl : string = "" ) : <async,exn,net,ndet> http-response
  request-url(Nothing, method, url, headers, body, max-redirects, Tls-opts(tls-ca, tls-cert, tls-key, tls-crl))

// TLS settings of a client
struct tls-opts
  ca : string
  cert : string
  key : string
  crl : string

fun request-url( client : maybe<http-client>, method : string, url : string, headers : headers, body : bytes, max-redirects : int, tls : tls-opts ) : <async,exn,net,ndet> http-response
  val u = match parse-url(url)
    Just(u) -> u
    Nothing -> throw("http: invalid url " ++ url.show)
  // ask for compressed responses and decode them, unless the caller chose the encodings
  val decode = headers.header("Accept-Encoding").is-nothing
  val hs = if decode then headers ++ [("Accept-Encoding", "gzip, deflate")] else headers
  val res = if max-redirects <= 0 then send-request(client, method, u, hs, body, tls)
            else follow-redirects(client, method, u, hs, body, max-redirects, tls)
  if decode then res.decode-content else res

// Undo the `Content-Encoding` of a response body (gzip and deflate). Unknown
// encodings are left as they are.
fun decode-content( res : http-response ) : exn http-response
  match res.header("Content-Encoding")
    Nothing -> res
    Just(ce) ->
      val codings = ce.split(",").map(fn(c) c.trim.to-lower).filter(fn(c) !c.is-empty && c != "identity")
      if codings.is-empty || codings.any(fn(c) c != "gzip" && c != "x-gzip" && c != "deflate") then res
      elif res.body.is-empty then res(headers = res.headers.remove-headers(["Content-Encoding"]))
      else
        val body = codings.reverse.foldl(res.body) fn(b, c)
          if c == "deflate" then
            // "deflate" should be zlib data, but some servers send raw deflate
            match try({ b.decompress(Zlib) })
              Ok(d) -> d
              Error(_) -> b.inflate
          else b.gunzip
        val hs = res.headers.remove-headers(["Content-Encoding", "Content-Length"]) ++ [("Content-Length", body.length.show)]
        res(headers = hs, body = body)

// Compress a response with gzip when the client accepts it (`Accept-Encoding`),
// the body is at least `min-size` bytes, its `Content-Type` is a kind of text
// (`text/*`, JSON, JavaScript, XML, SVG), and it is not encoded already.
// `http-serve` does this for every response with `compress = True`.
pub fun gzip-response( req : http-request, res : http-response, min-size : int = 1024 ) : http-response
  val ctype = res.header("Content-Type").default("").to-lower
  val compressible = ctype.starts-with("text/").is-just || ["json", "javascript", "xml", "svg"].any(fn(k) ctype.contains(k))
  if res.body.length < min-size || !compressible || res.header("Content-Encoding").is-just || !accepts-gzip(req) then res
  else
    val packed = res.body.gzip
    val vary = match res.header("Vary")
      Nothing -> "Accept-Encoding"
      Just(v) -> v ++ ", Accept-Encoding"
    val hs = res.headers.remove-headers(["Content-Length", "Vary"]) ++ [("Content-Encoding", "gzip"), ("Vary", vary)]
    res(headers = hs, body = packed)

// Does the request accept gzip (and not with `q=0`)?
fun accepts-gzip( req : http-request ) : bool
  match req.header("Accept-Encoding")
    Nothing -> False
    Just(ae) -> ae.split(",").any fn(item)
      val parts = item.split(";").map(fn(p) p.trim.to-lower)
      val name = parts.head.default("")
      val q-zero = parts.drop(1).any(fn(p) p == "q=0" || p == "q=0.0" || p == "q=0.00" || p == "q=0.000")
      (name == "gzip" || name == "x-gzip" || name == "*") && !q-zero

fun follow-redirects( client : maybe<http-client>, method : string, u : url, headers : headers, body : bytes, redirects-left : int, tls : tls-opts ) : <async,exn,net,ndet> http-response
  val res = send-request(client, method, u, headers, body, tls)
  val is-redirect = res.status == 301 || res.status == 302 || res.status == 303 || res.status == 307 || res.status == 308
  match res.header("Location")
    Just(location) | is-redirect && redirects-left > 0 ->
      val next = u.resolve(location.trim)
      val to-get = res.status == 303 && method != "HEAD" || (res.status == 301 || res.status == 302) && method == "POST"
      val (method', body', hs1) = if to-get
        then ("GET", bytes/empty, headers.remove-headers(["Content-Type", "Content-Length", "Transfer-Encoding"]))
        else (method, body, headers)
      val hs2 = if same-origin(u, next) then hs1 else hs1.remove-headers(["Authorization", "Cookie"])
      follow-redirects(client, method', next, hs2, body', pretend-decreasing(redirects-left - 1), tls)
    _ | is-redirect && res.header("Location").is-just ->
      throw("http: too many redirects (the last one was to " ++ res.header("Location").default("").show ++ ")")
    _ -> res

fun remove-headers( hs : headers, names : list<string> ) : headers
  val lnames = names.map(to-lower)
  hs.filter(fn((n, _)) !lnames.any(fn(l) l == n.to-lower))

fun same-origin( a : url, b : url ) : bool
  a.scheme == b.scheme && a.host.to-lower == b.host.to-lower && a.effective-port == b.effective-port

fun is-idempotent( method : string ) : bool
  match method
    "GET" -> True
    "HEAD" -> True
    "OPTIONS" -> True
    "TRACE" -> True
    "PUT" -> True
    "DELETE" -> True
    _ -> False

// Send one request (no redirects), on a pooled connection if there is a client.
fun send-request( client : maybe<http-client>, method : string, u : url, headers : headers, body : bytes, tls : tls-opts ) : <async,exn,net,ndet> http-response
  if u.scheme != "http" && u.scheme != "https" then throw("http: unsupported url scheme " ++ u.scheme.show)
  val conn-port = u.effective-port.default(80)
  val target = (if u.path.is-empty then "/" else u.path) ++ (if u.has-query then "?" ++ u.query else "")
  val host-header = if u.port.is-just then u.host ++ ":" ++ conn-port.show else u.host
  val hs0 = headers.set-header("Host", host-header)
  val hs1 = if client.is-just then hs0 else hs0.set-header("Connection", "close")
  val hs = if hs1.header("User-Agent").is-just then hs1 else hs1.set-header("User-Agent", "koka-http")
  val start-line = method ++ " " ++ target ++ " HTTP/1.1"
  fun connect() : <async,exn,net> net-stream
    if u.scheme == "https" then tls-connect(u.host, conn-port, ca = tls.ca, cert = tls.cert, key = tls.key, crl = tls.crl) else plain-stream(tcp-connect(u.host, conn-port))
  match client
    Nothing ->
      val s = connect()
      with finally { s.close }
      val sent = catch(fn(e) Just(e), { write-message(s, start-line, hs, body); Nothing })
      val (res, _, _) = match sent
        Nothing -> read-response(Reader(s, bytes/empty), method)
        Just(err) -> early-response(s, method, err)
      res
    Just(c) ->
      val origin = u.scheme ++ "://" ++ u.host.to-lower ++ ":" ++ conn-port.show
      val use-h2 = (u.scheme == "https" && c.http2) || (u.scheme == "http" && c.h2c)
      fun on-h2( h : h2conn ) : <async,exn,ndet> maybe<http-response>
        match h.h2-request(method, u.scheme, host-header, target, hs, body)
          Just((status, rhs, rbody)) -> Just(Http-response(status, reason-phrase(status), rhs, rbody, "HTTP/2"))
          Nothing -> Nothing   // refused by the server (it is closing the connection): try a new one
      // an open HTTP/2 connection to the origin; if another request is
      // connecting to it, wait for that first
      val dialer = use-h2 && c.find-h2(origin).is-nothing && c.begin-dial(origin, 0)
      val on-existing = if !use-h2 || dialer then Nothing else match c.find-h2(origin)
        Just(h) -> on-h2(h)
        Nothing -> Nothing
      match on-existing
        Just(res) -> res
        Nothing ->
          // an idle connection may have been closed by the server in the meantime:
          // then an idempotent request is retried on a new connection
          val on-idle = match c.take-idle(origin)
            Just(s) -> c.exchange(origin, s, method.is-idempotent, start-line, hs, body, method)
            Nothing -> Nothing
          match on-idle
            Just(res) -> res
            Nothing ->
              // a new connection, using HTTP/2 if the server agrees
              val dialed : ref<global,bool> = async-ioc { ref(False) }
              with finally
                val done = async-ioc { !dialed }
                if dialer && !done then c.end-dial(origin, False)
              val s = if u.scheme == "https" then tls-connect(u.host, conn-port, ca = tls.ca, cert = tls.cert, key = tls.key, crl = tls.crl, alpn = if c.http2 then ["h2", "http/1.1"] else [])
                      else plain-stream(tcp-connect(u.host, conn-port))
              val is-h2 = if u.scheme == "https" then s.alpn-protocol == Just("h2") else c.h2c
              if is-h2 then
                val h = h2-connect(s)
                async-ioc { c.set-h2(read-h2(c.h2conns) ++ [(origin, h)]) }
                if dialer then
                  async-ioc { dialed := True }
                  c.end-dial(origin, False)
                match on-h2(h)
                  Just(res) -> res
                  Nothing -> throw("http: the server refused the request")
              else
                if dialer then
                  async-ioc { dialed := True }
                  c.end-dial(origin, u.scheme == "https")
                match c.exchange(origin, s, False, start-line, hs, body, method)
                  Just(res) -> res
                  Nothing -> impossible("http: exchange on a new connection")

fun read-response( r : reader, method : string ) : <async,exn> (http-response, reader, bool)
  match r.read-until(crlfcrlf, 64 * 1024)
    Nothing -> throw("http: connection closed before the response")
    Just((head-bytes, r1)) ->
      val lines = head-bytes.string.split("\r\n")
      val status-line = lines.head.default("")
      val parts = status-line.split(" ")
      val status = match parts.drop(1).head.map(fn(t) parse-int(t))
        Just(Just(n)) -> n
        _ -> throw("http: invalid status line " ++ status-line.show)
      if status >= 100 && status < 200 && status != 101 then
        read-response(pretend-decreasing(r1), method)   // skip informational responses
      else
        val hs = parse-headers(lines.drop(1))
        val no-body = method == "HEAD" || status == 204 || status == 304
        val (res-body, r2) = if no-body then (bytes/empty, r1) else r1.read-body(hs, True)
        // can the connection be used for another request?
        val conn = hs.header("Connection").default("").to-lower
        val framed = no-body || hs.header("Content-Length").is-just || hs.header("Transfer-Encoding").default("").to-lower.contains("chunked")
        val reusable = framed && !conn.contains("close") && (parts.head == Just("HTTP/1.1") || conn.contains("keep-alive"))
        (Http-response(status, parts.drop(2).join(" "), hs, res-body), r2, reusable)

// ----------------------------------------------------------------------------
// Streaming bodies (client)
// ----------------------------------------------------------------------------

// The body of a response as a stream, read from the connection as it is consumed.
fun body-stream( r : reader, hs : headers ) : byte-stream<<async,exn|e>>
  val te = hs.header("Transfer-Encoding").default("").to-lower
  if te.find("chunked").is-just then chunked-stream(r, fn(_) ())
  else match hs.header("Content-Length").map(fn(cl) cl.trim.parse-int)
    Just(Just(n)) -> length-stream(r, n, fn(_) ())
    Just(Nothing) -> seq/suspend(fn() throw("http: invalid Content-Length"))
    Nothing -> eof-stream(r)

// `left` more bytes. At the end, `at-end` gets the reader after the body.
fun length-stream( r : reader, left : int, at-end : reader -> () ) : byte-stream<<async,exn|e>>
  seq/suspend fn()
    if left <= 0 then
      at-end(r)
      Done
    elif !r.buf.is-empty then
      val n = min(left, r.buf.length)
      Yield(r.buf.subbytes(0, n), length-stream(Reader(r.sock, r.buf.subbytes(n)), pretend-decreasing(left - n), at-end))
    else
      val more = r.sock.read
      if more.is-empty then throw("http: connection closed in the middle of a message body")
      val n = min(left, more.length)
      Yield(more.subbytes(0, n), length-stream(Reader(r.sock, more.subbytes(n)), pretend-decreasing(left - n), at-end))

// Everything until the connection is closed.
fun eof-stream( r : reader ) : byte-stream<<async,exn|e>>
  seq/suspend fn()
    if !r.buf.is-empty then Yield(r.buf, eof-stream(pretend-decreasing(Reader(r.sock, bytes/empty))))
    else
      val more = r.sock.read
      if more.is-empty then Done else Yield(more, eof-stream(pretend-decreasing(Reader(r.sock, bytes/empty))))

// A chunked body (RFC 9112 section 7.1), one chunk at a time. At the end,
// `at-end` gets the reader after the body.
fun chunked-stream( r : reader, at-end : reader -> () ) : byte-stream<<async,exn|e>>
  seq/suspend fn()
    match r.read-until(crlf, 1024)
      Nothing -> throw("http: connection closed in a chunked body")
      Just((line, r1)) ->
        val size-text = line.string.split(";").head.default("").trim
        val size = match parse-int(size-text, hex = True)
          Just(n) -> n
          Nothing -> throw("http: invalid chunk size " ++ size-text.show)
        if size == 0 then
          at-end(skip-trailers(r1))
          Done
        else
          val (chunk, r2) = r1.read-exact(size)
          val (_, r3) = r2.read-exact(2)   // CRLF after the chunk
          Yield(chunk, chunked-stream(pretend-decreasing(r3), at-end))

// Send a request whose body is a stream, with chunked transfer encoding.
fun write-streamed( s : net-stream, start-line : string, hs : headers, upload : byte-stream<<async,exn|e>> ) : <async,exn,div|e> ()
  val hsc = hs.remove-headers(["Content-Length"]).set-header("Transfer-Encoding", "chunked")
  s.write-all(head-text(start-line, hsc).bytes)
  upload.foreach fn(part)
    if !part.is-empty then
      s.write-all((part.length.show-hex(use-capitals = False, pre = "") ++ "\r\n").bytes ++ part ++ "\r\n".bytes)
  s.write-all("0\r\n\r\n".bytes)

// Send a request and give `action` the response with its body as a stream
// (`body` of the response is empty), read from the connection while `action`
// consumes it; the connection is closed afterwards. The request body is
// `body`, or `upload` (a stream, sent with chunked transfer encoding). Bodies
// encoded with gzip or deflate are decoded, unless `headers` contain an
// `Accept-Encoding`. Redirects are followed as in `http-request` (but not
// for an `upload`, which cannot be sent twice). HTTP/1.1 is used.
//
// ```
// http-stream("GET", "https://example.com/big.log") fn(res, body)
//   body.lines.filter(fn(l) l.contains("ERROR")).foreach(println)
// ```
pub fun http-stream( method : string, url : string, action : (http-response, byte-stream<<async,exn,net,ndet|e>>) -> <async,exn,net,ndet,div|e> a,
                     headers : headers = [], body : bytes = bytes/empty, upload : maybe<byte-stream<<async,exn,net,ndet|e>>> = Nothing,
                     max-redirects : int = 10, tls-ca : string = "", tls-cert : string = "", tls-key : string = "", tls-crl : string = "" ) : <async,exn,net,ndet,div|e> a
  val u = match parse-url(url)
    Just(u) -> u
    Nothing -> throw("http: invalid url " ++ url.show)
  val decode = headers.header("Accept-Encoding").is-nothing
  val hs = if decode then headers ++ [("Accept-Encoding", "gzip, deflate")] else headers
  stream-url(method, u, hs, body, upload, if upload.is-just then 0 else max-redirects, Tls-opts(tls-ca, tls-cert, tls-key, tls-crl), decode, action)

// Either a redirect to follow, or the result of the action.
type stream-outcome<a>
  Follow( method : string, u : url, headers : headers, body : bytes )
  Finished( result : a )

fun stream-url( method : string, u : url, headers : headers, body : bytes, upload : maybe<byte-stream<<async,exn,net,ndet|e>>>, redirects-left : int,
                tls : tls-opts, decode : bool, action : (http-response, byte-stream<<async,exn,net,ndet|e>>) -> <async,exn,net,ndet,div|e> a ) : <async,exn,net,ndet,div|e> a
  match stream-once(method, u, headers, body, upload, redirects-left, tls, decode, action)
    Follow(m, next, hs, b) -> stream-url(m, next, hs, b, Nothing, pretend-decreasing(redirects-left - 1), tls, decode, action)
    Finished(x) -> x

fun stream-once( method : string, u : url, headers : headers, body : bytes, upload : maybe<byte-stream<<async,exn,net,ndet|e>>>, redirects-left : int,
                 tls : tls-opts, decode : bool, action : (http-response, byte-stream<<async,exn,net,ndet|e>>) -> <async,exn,net,ndet,div|e> a ) : <async,exn,net,ndet,div|e> stream-outcome<a>
  if u.scheme != "http" && u.scheme != "https" then throw("http: unsupported url scheme " ++ u.scheme.show)
  val conn-port = u.effective-port.default(80)
  val target = (if u.path.is-empty then "/" else u.path) ++ (if u.has-query then "?" ++ u.query else "")
  val host-header = if u.port.is-just then u.host ++ ":" ++ conn-port.show else u.host
  val hs0 = headers.set-header("Host", host-header).set-header("Connection", "close")
  val hs = if hs0.header("User-Agent").is-just then hs0 else hs0.set-header("User-Agent", "koka-http")
  val start-line = method ++ " " ++ target ++ " HTTP/1.1"
  val s = if u.scheme == "https" then tls-connect(u.host, conn-port, ca = tls.ca, cert = tls.cert, key = tls.key, crl = tls.crl)
          else plain-stream(tcp-connect(u.host, conn-port))
  with finally { s.close }
  val sent = match upload
    Just(up) ->   // (errors of the upload stream itself are raised)
      write-streamed(s, start-line, hs, up)
      Nothing
    Nothing -> catch(fn(e) Just(e), { write-message(s, start-line, hs, body); Nothing })
  // if sending failed, the server may still have answered
  val (status, reason, rhs, r) = match sent
    Nothing -> read-head(Reader(s, bytes/empty))
    Just(err) -> match catch(fn(_) Nothing, { Just(read-head(Reader(s, bytes/empty))) })
      Just(head) -> head
      Nothing -> throw-exn(err)
  val is-redirect = status == 301 || status == 302 || status == 303 || status == 307 || status == 308
  match rhs.header("Location")
    Just(location) | is-redirect && redirects-left > 0 ->
      val next = u.resolve(location.trim)
      val to-get = status == 303 && method != "HEAD" || (status == 301 || status == 302) && method == "POST"
      val (m, b, hs1) = if to-get then ("GET", bytes/empty, headers.remove-headers(["Content-Type", "Content-Length", "Transfer-Encoding"]))
                        else (method, body, headers)
      val hs2 = if same-origin(u, next) then hs1 else hs1.remove-headers(["Authorization", "Cookie"])
      Follow(m, next, hs2, b)
    _ | is-redirect && rhs.header("Location").is-just && redirects-left <= 0 && upload.is-nothing ->
      throw("http: too many redirects (the last one was to " ++ rhs.header("Location").default("").show ++ ")")
    _ ->
      val no-body = method == "HEAD" || status == 204 || status == 304
      val raw-stream = if no-body then seq/empty() else body-stream(r, rhs)
      val codings = rhs.header("Content-Encoding").default("").split(",").map(fn(c) c.trim.to-lower).filter(fn(c) !c.is-empty && c != "identity")
      val known = !codings.is-nil && codings.all(fn(c) c == "gzip" || c == "x-gzip" || c == "deflate")
      val (stream, hs-out) = if decode && known then
          (codings.foldl(raw-stream, fn(st, _) st.decompress(Auto)), rhs.remove-headers(["Content-Encoding", "Content-Length"]))
        else (raw-stream, rhs)
      Finished(action(Http-response(status, reason, hs-out, bytes/empty, "HTTP/1.1"), stream))

// Read the status line and headers (skipping informational responses).
fun read-head( r : reader ) : <async,exn> (int, string, headers, reader)
  match r.read-until(crlfcrlf, 64 * 1024)
    Nothing -> throw("http: connection closed before the response")
    Just((head-bytes, r1)) ->
      val lines = head-bytes.string.split("\r\n")
      val status-line = lines.head.default("")
      val parts = status-line.split(" ")
      val status = match parts.drop(1).head.map(fn(t) parse-int(t))
        Just(Just(n)) -> n
        _ -> throw("http: invalid status line " ++ status-line.show)
      if status >= 100 && status < 200 && status != 101 then read-head(pretend-decreasing(r1))
      else (status, parts.drop(2).join(" "), parse-headers(lines.drop(1)), r1)

// ----------------------------------------------------------------------------
// Clients with connection reuse
// ----------------------------------------------------------------------------

value struct idle-conn
  origin : string       // scheme, host, port, and CA
  stream : net-stream
  expires : int         // in milliseconds (`ticks`)

// An HTTP client that keeps connections open (keep-alive) and reuses them for
// later requests to the same scheme, host and port. It can be used by several
// strands at once; each request uses its own connection.
abstract struct http-client
  idle : ref<global,list<idle-conn>>
  max-idle : int
  idle-timeout-ms : int
  tls : tls-opts
  http2 : bool                          // offer HTTP/2 for `https` (with ALPN)
  h2c : bool                            // use HTTP/2 for `http` (with prior knowledge)
  h2conns : ref<global,list<(string, h2conn)>>   // HTTP/2 connections by origin
  dialing : ref<global,list<(string, list<channel<()>>)>>   // origins being connected to, with waiting requests
  h1-only : ref<global,list<string>>                         // origins whose server did not choose HTTP/2

// (a signature is needed here: inferring the effect of reading the ref fails)
fun read-idle( r : ref<global,list<idle-conn>> ) : <read<global>,div> list<idle-conn>
  !r

fun read-h2( r : ref<global,list<(string, h2conn)>> ) : <read<global>,div> list<(string, h2conn)>
  !r

fun set-h2( c : http-client, xs : list<(string, h2conn)> ) : <write<global>,div> ()
  val r = c.h2conns
  r := xs

fun read-dialing( r : ref<global,list<(string, list<channel<()>>)>> ) : <read<global>,div> list<(string, list<channel<()>>)>
  !r

fun set-dialing( c : http-client, xs : list<(string, list<channel<()>>)> ) : <write<global>,div> ()
  val r = c.dialing
  r := xs

fun read-h1-only( r : ref<global,list<string>> ) : <read<global>,div> list<string>
  !r

fun set-h1-only( c : http-client, xs : list<string> ) : <write<global>,div> ()
  val r = c.h1-only
  r := xs

// Create a client that keeps up to `max-idle-per-host` idle connections per
// host open. Close it with `close` (or use `with client = http-client()`).
//
// An idle connection is not reused after `idle-timeout`, or earlier if the
// server announces a shorter timeout (`Keep-Alive: timeout=N`; a connection is
// then kept one second less than that). The default of 4 seconds stays below
// the 5 second timeout of many servers. Expired connections are closed the
// next time the client is used.
//
// For `https`, `tls-ca`, `tls-cert` and `tls-key` are used as in `http-request`.
//
// With `http2` (the default), `https` connections offer HTTP/2 (with ALPN);
// when a server accepts, all requests to it share one connection. With
// `h2c`, plain `http` requests use HTTP/2 directly ("prior knowledge"), which
// only works with servers that support it.
pub fun http-client( max-idle-per-host : int = 4, idle-timeout : duration = 4.seconds,
                     tls-ca : string = "", tls-cert : string = "", tls-key : string = "",
                     http2 : bool = True, h2c : bool = False, tls-crl : string = "" ) : async http-client
  async-ioc { Http-client(ref([]), max-idle-per-host, idle-timeout.milli-seconds, Tls-opts(tls-ca, tls-cert, tls-key, tls-crl), http2, h2c, ref([]), ref([]), ref([])) }

// Create a client, run `action` with it, and close it afterwards.
pub fun scoped/http-client( action : http-client -> <async,exn|e> a, max-idle-per-host : int = 4, idle-timeout : duration = 4.seconds,
                            tls-ca : string = "", tls-cert : string = "", tls-key : string = "",
                            http2 : bool = True, h2c : bool = False, tls-crl : string = "" ) : <async,exn|e> a
  val c = http-client(max-idle-per-host, idle-timeout, tls-ca, tls-cert, tls-key, http2, h2c, tls-crl)
  with finally { c.close }
  action(c)

// Close all idle connections. The client can still be used afterwards.
pub fun http-client/close( c : http-client ) : async ()
  val conns = async-ioc
    val r : ref<global,list<idle-conn>> = c.idle
    val xs = read-idle(r)
    r := []
    xs
  conns.foreach(fn(ic) ic.stream.close)
  val h2s = async-ioc
    val xs = read-h2(c.h2conns)
    c.set-h2([])
    xs
  h2s.foreach(fn((_, h)) h.h2-close)

fun now-ms() : async int
  async-ioc { ticks().milli-seconds }

// Remove the expired idle connections and close them.
fun prune( c : http-client, now : int ) : async ()
  val expired = async-ioc
    val r : ref<global,list<idle-conn>> = c.idle
    val xs = read-idle(r)
    r := xs.filter(fn(ic) ic.expires > now)
    xs.filter(fn(ic) ic.expires <= now)
  expired.foreach(fn(ic) ic.stream.close)
  // HTTP/2 connections that failed, or that were idle for too long
  val h2s = async-ioc { read-h2(c.h2conns) }
  h2s.foreach fn((_, h))
    val unusable = !h.h2-is-open || (h.h2-active == 0 && h.h2-last-used + c.idle-timeout-ms <= now)
    if unusable then
      async-ioc { c.set-h2(read-h2(c.h2conns).filter(fn((_, x)) !x.h2-same(h))) }
      h.h2-close

// Wait while another request connects to the same origin (it may get an
// HTTP/2 connection that can be shared). Returns `True` if this request
// should connect itself, after which it must call `end-dial`.
fun begin-dial( c : http-client, key : string, round : int ) : <async,ndet> bool
  val known-h1 = async-ioc { read-h1-only(c.h1-only).any(fn(o) o == key) }
  if known-h1 then return False
  val ch = channel()
  val wait = async-ioc
    val xs = read-dialing(c.dialing)
    match xs.lookup(fn(o) o == key)
      Just(_) ->
        c.set-dialing(xs.map(fn((o, ws)) if o == key then (o, Cons(ch, ws)) else (o, ws)))
        True
      Nothing ->
        c.set-dialing(Cons((key, []), xs))
        False
  if !wait then True
  else
    ch.receive
    match c.find-h2(key)
      Just(_) -> False
      Nothing -> c.begin-dial(key, pretend-decreasing(round + 1))

// The connection attempt for `key` is done; `h1` records that the server chose HTTP/1.1.
fun end-dial( c : http-client, key : string, h1 : bool ) : async ()
  async-ioc
    val xs = read-dialing(c.dialing)
    xs.foreach(fn((o, ws)) if o == key then ws.foreach(fn(w) emit-io(w, ())))
    c.set-dialing(xs.filter(fn((o, _)) o != key))
    if h1 then c.set-h1-only(Cons(key, read-h1-only(c.h1-only).filter(fn(o) o != key)))

// An open HTTP/2 connection to an origin.
fun find-h2( c : http-client, key : string ) : async maybe<h2conn>
  c.prune(now-ms())
  val h2s = async-ioc { read-h2(c.h2conns) }
  h2s.filter(fn((k, _)) k == key).map(snd).head

fun take-idle( c : http-client, key : string ) : async maybe<net-stream>
  c.prune(now-ms())
  async-ioc
    val r : ref<global,list<idle-conn>> = c.idle
    val (found, rest) = remove-first(read-idle(r), key)
    r := rest
    found

fun remove-first( xs : list<idle-conn>, key : string ) : (maybe<net-stream>, list<idle-conn>)
  match xs
    Cons(ic, rest) ->
      if ic.origin == key then (Just(ic.stream), rest)
      else
        val (found, rest') = remove-first(rest, key)
        (found, Cons(ic, rest'))
    Nil -> (Nothing, Nil)

// Keep `s` for at most `lifetime` milliseconds.
fun put-idle( c : http-client, key : string, s : net-stream, lifetime : int ) : async ()
  val now = now-ms()
  c.prune(now)
  val stored = async-ioc
    val r : ref<global,list<idle-conn>> = c.idle
    val xs = read-idle(r)
    if lifetime <= 0 || xs.filter(fn(ic) ic.origin == key).length >= c.max-idle then False
    else
      r := Cons(Idle-conn(key, s, now + lifetime), xs)
      True
  if !stored then s.close

// How long a connection may stay idle after a response with headers `hs`, in milliseconds.
fun idle-lifetime( c : http-client, hs : headers ) : int
  val announced = hs.header("Keep-Alive").default("").split(",").map(trim).foldl(Nothing) fn(acc, param)
    match param.to-lower.starts-with("timeout=")
      Just(rest) -> parse-int(rest.string.trim)
      Nothing -> acc
  match announced
    Just(secs) -> min(max(0, secs - 1) * 1000, c.idle-timeout-ms)
    Nothing -> c.idle-timeout-ms

// Send a request on `s` and read the response; afterwards the connection is
// put back in the pool if it can be reused, and closed otherwise (also on
// errors and cancelation). With `can-retry`, returns `Nothing` if the
// connection turns out to be closed before any response arrives.
fun exchange( c : http-client, key : string, s : net-stream, can-retry : bool,
              start-line : string, hs : headers, body : bytes, method : string ) : <async,exn> maybe<http-response>
  val keep : ref<global,int> = async-ioc { ref(0) }   // the idle lifetime if the connection can be reused
  with finally
    val lifetime = async-ioc { !keep }
    if lifetime > 0 then c.put-idle(key, s, lifetime) else s.close
  // if sending fails, the server may still have answered (before it closed the connection)
  val sent = catch(fn(e) Just(e), { write-message(s, start-line, hs, body); Nothing })
  val started = catch(fn(exn) Error(exn), { Ok(Reader(s, bytes/empty).fill) })
  match started
    Ok((True, r)) ->
      val (res, rest, reusable) = read-response(r, method)
      if reusable && rest.buf.is-empty && sent.is-nothing then
        val lifetime = c.idle-lifetime(res.headers)
        async-ioc { keep := lifetime }
      Just(res)
    _ | can-retry -> Nothing
    Ok(_) -> match sent
      Just(err) -> throw-exn(err)
      Nothing -> throw("http: connection closed before the response")
    Error(exn) -> throw-exn(sent.default(exn))

// Sending a request failed with `err`: read the response the server may have
// sent before it closed the connection (for example, after rejecting a large
// body without reading it); raise `err` if there is none.
fun early-response( s : net-stream, method : string, err : exception ) : <async,exn> (http-response, reader, bool)
  match catch(fn(_) Nothing, { Just(read-response(Reader(s, bytes/empty), method)) })
    Just((res, r, _)) -> (res, r, False)
    Nothing -> throw-exn(err)

// Send an HTTP request through the client (see `http-request`).
pub fun client/http-request( c : http-client, method : string, url : string, headers : headers = [], body : bytes = bytes/empty, max-redirects : int = 10 ) : <async,exn,net,ndet> http-response
  request-url(Just(c), method, url, headers, body, max-redirects, c.tls)

// `GET` a URL through the client.
pub fun client/http-get( c : http-client, url : string, headers : headers = [], max-redirects : int = 10 ) : <async,exn,net,ndet> http-response
  request-url(Just(c), "GET", url, headers, bytes/empty, max-redirects, c.tls)

// `POST` a body to a URL through the client.
pub fun client/http-post( c : http-client, url : string, body : bytes, content-type : string = "application/octet-stream", headers : headers = [], max-redirects : int = 10 ) : <async,exn,net,ndet> http-response
  request-url(Just(c), "POST", url, headers.set-header("Content-Type", content-type), body, max-redirects, c.tls)

// `GET` a URL.
pub fun http-get( url : string, headers : headers = [], max-redirects : int = 10,
                  tls-ca : string = "", tls-cert : string = "", tls-key : string = "", tls-crl : string = "" ) : <async,exn,net,ndet> http-response
  http-request("GET", url, headers, max-redirects = max-redirects, tls-ca = tls-ca, tls-cert = tls-cert, tls-key = tls-key, tls-crl = tls-crl)

// `POST` a body to a URL.
pub fun http-post( url : string, body : bytes, content-type : string = "application/octet-stream", headers : headers = [], max-redirects : int = 10,
                   tls-ca : string = "", tls-cert : string = "", tls-key : string = "", tls-crl : string = "" ) : <async,exn,net,ndet> http-response
  http-request("POST", url, headers.set-header("Content-Type", content-type), body, max-redirects, tls-ca, tls-cert, tls-key, tls-crl)

// `GET` a URL and return the body as text; raises an exception unless the status is 2xx.
pub fun http-get-text( url : string ) : <async,exn,net,ndet> string
  val res = http-get(url)
  if res.status < 200 || res.status >= 300 then throw("http: GET " ++ url ++ " returned " ++ res.status.show)
  res.body-text

// ----------------------------------------------------------------------------
// Server
// ----------------------------------------------------------------------------

// Serve HTTP requests on a listening TCP server, forever. Each connection is
// handled in its own strand and may carry several requests (keep-alive).
// An exception in `on-request` results in a `500` response. With a `tls`
// configuration, connections use TLS (`https`); connections that fail the
// TLS handshake are dropped.
//
// HTTP/2 is used when TLS negotiates it (include `"h2"` in the `alpn` of the
// TLS configuration, as in `alpn = ["h2", "http/1.1"]`), and for plain
// connections from clients that start with HTTP/2 directly (prior knowledge).
//
// A connection is closed when no new request starts within `idle-timeout`
// after a response (announced to clients with a `Keep-Alive` header), or when
// receiving a request takes longer than `request-timeout` (answered with
// `408 Request Timeout`).
//
// With `compress = True`, text responses are compressed with gzip for clients
// that accept it (see `gzip-response`).
pub fun http-serve( srv : tcp-server, on-request : http-request -> <async,exn,ndet|e> http-response, tls : maybe<tls-config> = Nothing,
                    idle-timeout : duration = 5.seconds, request-timeout : duration = 60.seconds, compress : bool = False ) : <async,exn,ndet|e> ()
  val serve-fn = if compress then (fn(req) gzip-response(req, on-request(req))) else on-request
  serve-all(srv, Buffered(serve-fn), tls, idle-timeout, request-timeout)

// Like `http-serve`, but `on-request` gets the request body as a stream
// (`body` of the request is empty), read from the connection as it is
// consumed; so large uploads need not fit in memory. Read the stream once,
// either in `on-request` or in the `body-writer` of the response (see
// `stream-response`). A client that sent `Expect: 100-continue` is told to
// continue when the body is first read. If the body is not read to the end,
// the connection is closed after the response (over HTTP/2: the stream is
// reset). `request-timeout` covers only the request line and headers.
//
// ```
// http-serve-stream(server) fn(req, body)
//   val n = body.foldl(0, fn(n, part) n + part.length)
//   text-response(200, "received " ++ n.show ++ " bytes")
// ```
pub fun http-serve-stream( srv : tcp-server, on-request : (http-request, byte-stream<<async,exn,ndet|e>>) -> <async,exn,ndet,div|e> http-response,
                           tls : maybe<tls-config> = Nothing, idle-timeout : duration = 5.seconds, request-timeout : duration = 60.seconds,
                           compress : bool = False ) : <async,exn,ndet|e> ()
  val serve-fn = if compress then (fn(req, body) gzip-response(req, on-request(req, body))) else on-request
  serve-all(srv, Streaming(serve-fn), tls, idle-timeout, request-timeout)

// A request handler: with the body read first, or as a stream.
type responder<e>
  Buffered( on-request : http-request -> <async,exn,ndet|e> http-response )
  Streaming( on-stream : (http-request, byte-stream<<async,exn,ndet|e>>) -> <async,exn,ndet,div|e> http-response )

fun responder/call( h : responder<e>, req : http-request, body : byte-stream<<async,exn,ndet|e>> ) : <async,exn,ndet|e> http-response
  match h
    Buffered(f)  -> f(req)
    Streaming(f) -> pretend-no-div { f(req, body) }

fun serve-all( srv : tcp-server, h : responder<e>, tls : maybe<tls-config>,
               idle-timeout : duration, request-timeout : duration ) : <async,exn,ndet|e> ()
  srv.serve fn(conn)
    match tls
      Nothing -> serve-connection(Reader(plain-stream(conn), bytes/empty), h, True, idle-timeout, request-timeout)
      Just(config) ->
        val s = conn.tls-accept(config)
        if s.alpn-protocol == Just("h2") then
          val (peer-ip, peer-port) = s.peer-address
          val client-cert = s.peer-certificate.default("")
          h2-serve(s, bytes/empty, h2-adapter(h, peer-ip ++ ":" ++ peer-port.show, client-cert), idle-timeout)
        else
          serve-connection(Reader(s, bytes/empty), h, True, idle-timeout, request-timeout)
          s.close-notify

// Adapt a request handler to HTTP/2 header lists; bodies are streamed both
// ways (a `Buffered` handler gets the request body collected).
fun h2-adapter( h : responder<e>, peer : string, client-cert : string ) : h2-handler<e>
  fn(hs, body-in)
    fun pseudo( name : string ) : string
      hs.lookup(fn(n) n == name).default("")
    val plain = hs.filter(fn((n, _)) !n.starts-with(":").is-just)
    val hs' = if plain.header("host").is-just then plain else Cons(("host", pseudo(":authority")), plain)
    val req = Http-request(pseudo(":method"), pseudo(":path"), hs', bytes/empty, peer, client-cert, "HTTP/2")
    val res = match h
      Buffered(f)  -> f(req(body = pretend-no-div { body-in.read-all }))
      Streaming(f) -> pretend-no-div { f(req, body-in) }
    match res.body-writer
      Just(w) -> (res.status, res.headers, H2-writer(w))
      Nothing -> (res.status, res.headers, H2-bytes(res.body))

// A request read by the server (its head, and with `Buffered` handlers its body).
type incoming
  In-closed                    // the client closed the connection
  In-bad                       // an invalid request line
  In-request( method : string, target : string, version : string, headers : headers, body : bytes, rest : reader )

fun read-request( r : reader, with-body : bool ) : <async,exn> incoming
  match r.read-until(crlfcrlf, 64 * 1024)
    Nothing -> In-closed
    Just((head-bytes, r1)) ->
      val lines = head-bytes.string.split("\r\n")
      match lines.head.default("").split(" ")
        [method, target, version] ->
          val hs = parse-headers(lines.drop(1))
          if with-body && !(method == "PRI" && version == "HTTP/2.0") then
            if expects-continue(version, hs) && has-body(hs) then r1.sock.write-all(continue-response)
            val (req-body, r2) = r1.read-body(hs, False)
            In-request(method, target, version, hs, req-body, r2)
          else In-request(method, target, version, hs, bytes/empty, r1)
        _ -> In-bad

val continue-response = "HTTP/1.1 100 Continue\r\n\r\n".bytes

fun expects-continue( version : string, hs : headers ) : bool
  version == "HTTP/1.1" && hs.header("Expect").map(fn(v) v.trim.to-lower) == Just("100-continue")

// Does a request have a body? (Requests without a length have none.)
fun has-body( hs : headers ) : bool
  hs.header("Transfer-Encoding").default("").to-lower.find("chunked").is-just ||
  hs.header("Content-Length").map(fn(cl) cl.trim.parse-int.default(0) > 0).default(False)

// The body of a request as a stream. When it was read to the end, `ended`
// holds the reader after it (so the next request on the connection can be
// read). An `Expect: 100-continue` is answered when the body is first read.
fun request-stream( r : reader, hs : headers, send-continue : bool, ended : ref<global,maybe<reader>> ) : byte-stream<<async,exn|e>>
  val at-end = fn(r-end : reader) unsafe-total { ended := Just(r-end) }
  val te = hs.header("Transfer-Encoding").default("").to-lower
  val body = if te.find("chunked").is-just then chunked-stream(r, at-end)
    else match hs.header("Content-Length").map(fn(cl) cl.trim.parse-int)
      Just(Just(n)) | n >= 0 -> length-stream(r, n, at-end)
      Just(_) -> seq/suspend(fn() throw("http: invalid Content-Length"))
      Nothing -> length-stream(r, 0, at-end)
  if !send-continue then body
  else seq/suspend fn()
    r.sock.write-all(continue-response)
    body.next

fun serve-connection( r : reader, h : responder<e>, first : bool,
                      idle-timeout : duration, request-timeout : duration ) : <async,exn,ndet|e> ()
  // wait (at most `idle-timeout`) for the next request to start
  val ready = if first || !r.buf.is-empty then Just(r) else
    match timeout(idle-timeout, { r.fill })
      Just((True, r1)) -> Just(r1)
      _ -> Nothing
  val buffered = match h
    Buffered -> True
    _ -> False
  match ready
    Nothing -> ()   // idle for too long, or closed by the client
    Just(r0) -> match timeout(request-timeout, { read-request(r0, buffered) })
      Nothing ->
        catch(fn(_) (), { write-message(r.sock, "HTTP/1.1 408 Request Timeout", [("Connection", "close")], "request timeout".bytes) })
      Just(In-closed) -> ()
      Just(In-bad) ->
        write-message(r.sock, "HTTP/1.1 400 Bad Request", [("Connection", "close")], "bad request".bytes)
      Just(In-request("PRI", "*", "HTTP/2.0", _, _, r2)) | first ->
        // the HTTP/2 connection preface: switch to HTTP/2 (prior knowledge)
        val (peer-ip, peer-port) = r.sock.peer-address
        h2-serve(r.sock, "PRI * HTTP/2.0\r\n\r\n".bytes ++ r2.buf, h2-adapter(h, peer-ip ++ ":" ++ peer-port.show, ""), idle-timeout)
      Just(In-request(method, target, version, hs, req-body, r2)) ->
        val (peer-ip, peer-port) = r.sock.peer-address
        val client-cert = r.sock.peer-certificate.default("")
        val req = Http-request(method, target, hs, req-body, peer-ip ++ ":" ++ peer-port.show, client-cert, version)
        // with a streamed body, the reader after the body is known once it was read to the end
        val ended : ref<global,maybe<reader>> = unsafe-total { ref(if buffered || !has-body(hs) then Just(r2) else Nothing) }
        val body = if buffered then seq/empty() else request-stream(r2, hs, expects-continue(version, hs), ended)
        val res = mask<exn>{ catch(fn(exn) text-response(500, "internal server error: " ++ exn.message), { h.call(req, body) }) }
        fun body-done() : maybe<reader>
          unsafe-total { !ended }
        val keep-alive = match hs.header("Connection").map(to-lower)
          _ | res.header("Connection").map(to-lower) == Just("close") -> False
          // an unread body that the response will not read either: close instead of reading it
          _ | body-done().is-nothing && res.body-writer.is-nothing -> False
          Just("close") -> False
          Just("keep-alive") -> True
          _ -> version == "HTTP/1.1"
        val idle-secs = idle-timeout.milli-seconds / 1000
        val hs1 = res.headers.set-header("Connection", if keep-alive then "keep-alive" else "close")
        val res-headers = if !keep-alive || idle-secs < 1 || res.header("Keep-Alive").is-just then hs1
                          else hs1.set-header("Keep-Alive", "timeout=" ++ idle-secs.show)
        val reason = if res.reason.is-empty then reason-phrase(res.status) else res.reason
        val status-line = "HTTP/1.1 " ++ res.status.show ++ " " ++ reason
        send-response(r.sock, method, version, status-line, res-headers, res)
        match body-done()
          Just(r3) | keep-alive -> serve-connection(pretend-decreasing(r3), h, False, idle-timeout, request-timeout)
          Nothing -> linger(r.sock)   // the request body was not read: the connection is closed
          _ -> ()

// Before closing a connection whose request body was not read, read (and
// discard) what the client still sends, for a while: closing a socket with
// unread data resets the connection, and the client could lose the response
// (RFC 9112 section 9.6).
fun linger( s : net-stream ) : <async,ndet> ()
  fun discard( left : int ) : <async,exn> ()
    if left > 0 then
      val more = s.read
      if !more.is-empty then discard(pretend-decreasing(left - more.length))
  catch(fn(_) (), { val _ = timeout(2.seconds, { discard(4 * 1024 * 1024) }); () })
