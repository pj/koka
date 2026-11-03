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
import std/time/duration
import std/time/timer
import async/async
import async/internal
import async/interleave
import async/os/net
import async/os/tls
import std/net/url
import std/text/encoding

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

// An HTTP response.
pub struct http-response
  status : int = 200
  reason : string = ""
  headers : headers = []
  body : bytes = bytes/empty

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
// For `https`, the server certificate is checked against the system CA
// certificates, or only against `tls-ca` (PEM certificates) if it is given.
// A client certificate (`tls-cert`, PEM) and its private key (`tls-key`) are
// presented to servers that ask for one.
pub fun http-request( method : string, url : string, headers : headers = [], body : bytes = bytes/empty, max-redirects : int = 10,
                      tls-ca : string = "", tls-cert : string = "", tls-key : string = "" ) : <async,exn,net> http-response
  request-url(Nothing, method, url, headers, body, max-redirects, Tls-opts(tls-ca, tls-cert, tls-key))

// TLS settings of a client
value struct tls-opts
  ca : string
  cert : string
  key : string

fun request-url( client : maybe<http-client>, method : string, url : string, headers : headers, body : bytes, max-redirects : int, tls : tls-opts ) : <async,exn,net> http-response
  val u = match parse-url(url)
    Just(u) -> u
    Nothing -> throw("http: invalid url " ++ url.show)
  if max-redirects <= 0 then send-request(client, method, u, headers, body, tls)
  else follow-redirects(client, method, u, headers, body, max-redirects, tls)

fun follow-redirects( client : maybe<http-client>, method : string, u : url, headers : headers, body : bytes, redirects-left : int, tls : tls-opts ) : <async,exn,net> http-response
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
fun send-request( client : maybe<http-client>, method : string, u : url, headers : headers, body : bytes, tls : tls-opts ) : <async,exn,net> http-response
  if u.scheme != "http" && u.scheme != "https" then throw("http: unsupported url scheme " ++ u.scheme.show)
  val conn-port = u.effective-port.default(80)
  val target = (if u.path.is-empty then "/" else u.path) ++ (if u.has-query then "?" ++ u.query else "")
  val host-header = if u.port.is-just then u.host ++ ":" ++ conn-port.show else u.host
  val hs0 = headers.set-header("Host", host-header)
  val hs1 = if client.is-just then hs0 else hs0.set-header("Connection", "close")
  val hs = if hs1.header("User-Agent").is-just then hs1 else hs1.set-header("User-Agent", "koka-http")
  val start-line = method ++ " " ++ target ++ " HTTP/1.1"
  fun connect() : <async,exn,net> net-stream
    if u.scheme == "https" then tls-connect(u.host, conn-port, ca = tls.ca, cert = tls.cert, key = tls.key) else plain-stream(tcp-connect(u.host, conn-port))
  match client
    Nothing ->
      val s = connect()
      with finally { s.close }
      write-message(s, start-line, hs, body)
      val (res, _, _) = read-response(Reader(s, bytes/empty), method)
      res
    Just(c) ->
      val key = u.scheme ++ "://" ++ u.host.to-lower ++ ":" ++ conn-port.show
      // an idle connection may have been closed by the server in the meantime:
      // then an idempotent request is retried on a new connection
      val on-idle = match c.take-idle(key)
        Just(s) -> c.exchange(key, s, method.is-idempotent, start-line, hs, body, method)
        Nothing -> Nothing
      match on-idle
        Just(res) -> res
        Nothing -> match c.exchange(key, connect(), False, start-line, hs, body, method)
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

// (a signature is needed here: inferring the effect of reading the ref fails)
fun read-idle( r : ref<global,list<idle-conn>> ) : <read<global>,div> list<idle-conn>
  !r

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
pub fun http-client( max-idle-per-host : int = 4, idle-timeout : duration = 4.seconds,
                     tls-ca : string = "", tls-cert : string = "", tls-key : string = "" ) : async http-client
  async-ioc { Http-client(ref([]), max-idle-per-host, idle-timeout.milli-seconds, Tls-opts(tls-ca, tls-cert, tls-key)) }

// Create a client, run `action` with it, and close it afterwards.
pub fun scoped/http-client( action : http-client -> <async,exn|e> a, max-idle-per-host : int = 4, idle-timeout : duration = 4.seconds,
                            tls-ca : string = "", tls-cert : string = "", tls-key : string = "" ) : <async,exn|e> a
  val c = http-client(max-idle-per-host, idle-timeout, tls-ca, tls-cert, tls-key)
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
  val started = catch(fn(exn) Error(exn), {
    write-message(s, start-line, hs, body)
    Ok(Reader(s, bytes/empty).fill)
  })
  match started
    Ok((True, r)) ->
      val (res, rest, reusable) = read-response(r, method)
      if reusable && rest.buf.is-empty then
        val lifetime = c.idle-lifetime(res.headers)
        async-ioc { keep := lifetime }
      Just(res)
    _ | can-retry -> Nothing
    Ok(_) -> throw("http: connection closed before the response")
    Error(exn) -> throw-exn(exn)

// Send an HTTP request through the client (see `http-request`).
pub fun client/http-request( c : http-client, method : string, url : string, headers : headers = [], body : bytes = bytes/empty, max-redirects : int = 10 ) : <async,exn,net> http-response
  request-url(Just(c), method, url, headers, body, max-redirects, c.tls)

// `GET` a URL through the client.
pub fun client/http-get( c : http-client, url : string, headers : headers = [], max-redirects : int = 10 ) : <async,exn,net> http-response
  request-url(Just(c), "GET", url, headers, bytes/empty, max-redirects, c.tls)

// `POST` a body to a URL through the client.
pub fun client/http-post( c : http-client, url : string, body : bytes, content-type : string = "application/octet-stream", headers : headers = [], max-redirects : int = 10 ) : <async,exn,net> http-response
  request-url(Just(c), "POST", url, headers.set-header("Content-Type", content-type), body, max-redirects, c.tls)

// `GET` a URL.
pub fun http-get( url : string, headers : headers = [], max-redirects : int = 10,
                  tls-ca : string = "", tls-cert : string = "", tls-key : string = "" ) : <async,exn,net> http-response
  http-request("GET", url, headers, max-redirects = max-redirects, tls-ca = tls-ca, tls-cert = tls-cert, tls-key = tls-key)

// `POST` a body to a URL.
pub fun http-post( url : string, body : bytes, content-type : string = "application/octet-stream", headers : headers = [], max-redirects : int = 10,
                   tls-ca : string = "", tls-cert : string = "", tls-key : string = "" ) : <async,exn,net> http-response
  http-request("POST", url, headers.set-header("Content-Type", content-type), body, max-redirects, tls-ca, tls-cert, tls-key)

// `GET` a URL and return the body as text; raises an exception unless the status is 2xx.
pub fun http-get-text( url : string ) : <async,exn,net> string
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
// A connection is closed when no new request starts within `idle-timeout`
// after a response (announced to clients with a `Keep-Alive` header), or when
// receiving a request takes longer than `request-timeout` (answered with
// `408 Request Timeout`).
pub fun http-serve( srv : tcp-server, on-request : http-request -> <async,exn,ndet|e> http-response, tls : maybe<tls-config> = Nothing,
                    idle-timeout : duration = 5.seconds, request-timeout : duration = 60.seconds ) : <async,exn,ndet|e> ()
  srv.serve fn(conn)
    match tls
      Nothing -> serve-connection(Reader(plain-stream(conn), bytes/empty), on-request, True, idle-timeout, request-timeout)
      Just(config) ->
        val s = conn.tls-accept(config)
        serve-connection(Reader(s, bytes/empty), on-request, True, idle-timeout, request-timeout)
        s.close-notify

// A request read by the server.
type incoming
  In-closed                    // the client closed the connection
  In-bad                       // an invalid request line
  In-request( method : string, target : string, version : string, headers : headers, body : bytes, rest : reader )

fun read-request( r : reader ) : <async,exn> incoming
  match r.read-until(crlfcrlf, 64 * 1024)
    Nothing -> In-closed
    Just((head-bytes, r1)) ->
      val lines = head-bytes.string.split("\r\n")
      match lines.head.default("").split(" ")
        [method, target, version] ->
          val hs = parse-headers(lines.drop(1))
          val (req-body, r2) = r1.read-body(hs, False)
          In-request(method, target, version, hs, req-body, r2)
        _ -> In-bad

fun serve-connection( r : reader, on-request : http-request -> <async,exn,ndet|e> http-response, first : bool,
                      idle-timeout : duration, request-timeout : duration ) : <async,exn,ndet|e> ()
  // wait (at most `idle-timeout`) for the next request to start
  val ready = if first || !r.buf.is-empty then Just(r) else
    match timeout(idle-timeout, { r.fill })
      Just((True, r1)) -> Just(r1)
      _ -> Nothing
  match ready
    Nothing -> ()   // idle for too long, or closed by the client
    Just(r0) -> match timeout(request-timeout, { read-request(r0) })
      Nothing ->
        catch(fn(_) (), { write-message(r.sock, "HTTP/1.1 408 Request Timeout", [("Connection", "close")], "request timeout".bytes) })
      Just(In-closed) -> ()
      Just(In-bad) ->
        write-message(r.sock, "HTTP/1.1 400 Bad Request", [("Connection", "close")], "bad request".bytes)
      Just(In-request(method, target, version, hs, req-body, r2)) ->
        val (peer-ip, peer-port) = r.sock.peer-address
        val client-cert = r.sock.peer-certificate.default("")
        val req = Http-request(method, target, hs, req-body, peer-ip ++ ":" ++ peer-port.show, client-cert)
        val res = mask<exn>{ catch(fn(exn) text-response(500, "internal server error: " ++ exn.message), { on-request(req) }) }
        val keep-alive = match hs.header("Connection").map(to-lower)
          _ | res.header("Connection").map(to-lower) == Just("close") -> False
          Just("close") -> False
          Just("keep-alive") -> True
          _ -> version == "HTTP/1.1"
        val idle-secs = idle-timeout.milli-seconds / 1000
        val hs1 = res.headers.set-header("Connection", if keep-alive then "keep-alive" else "close")
        val res-headers = if !keep-alive || idle-secs < 1 || res.header("Keep-Alive").is-just then hs1
                          else hs1.set-header("Keep-Alive", "timeout=" ++ idle-secs.show)
        val reason = if res.reason.is-empty then reason-phrase(res.status) else res.reason
        val res-body = if method == "HEAD" then bytes/empty else res.body
        write-message(r.sock, "HTTP/1.1 " ++ res.status.show ++ " " ++ reason, res-headers, res-body)
        if keep-alive then serve-connection(pretend-decreasing(r2), on-request, False, idle-timeout, request-timeout)
