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

   Bodies are framed with `Content-Length`, `Transfer-Encoding: chunked`, or
   (for responses) by the server closing the connection. The server supports
   persistent (keep-alive) connections; the client sends one request per
   connection and follows redirects.
*/
module async/os/http

import std/core/undiv
import async/async
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

// Send an HTTP request to `url` and return the response.
//
// Redirects (`301`, `302`, `303`, `307`, `308`) are followed up to
// `max-redirects` times, after which an exception is raised. With
// `max-redirects = 0` the redirect response itself is returned. As in browsers, a `303` (or a `301`/`302` after a `POST`) is
// followed with a `GET` without a body, while `307` and `308` repeat the
// original method and body. The `Authorization` and `Cookie` headers are
// dropped when a redirect leads to a different origin.
//
// For `https`, the server certificate is checked against the system CA
// certificates, or only against `tls-ca` (PEM certificates) if it is given.
pub fun http-request( method : string, url : string, headers : headers = [], body : bytes = bytes/empty, max-redirects : int = 10, tls-ca : string = "" ) : <async,exn,net> http-response
  val u = match parse-url(url)
    Just(u) -> u
    Nothing -> throw("http: invalid url " ++ url.show)
  if max-redirects <= 0 then send-request(method, u, headers, body, tls-ca)
  else follow-redirects(method, u, headers, body, max-redirects, tls-ca)

fun follow-redirects( method : string, u : url, headers : headers, body : bytes, redirects-left : int, tls-ca : string ) : <async,exn,net> http-response
  val res = send-request(method, u, headers, body, tls-ca)
  val is-redirect = res.status == 301 || res.status == 302 || res.status == 303 || res.status == 307 || res.status == 308
  match res.header("Location")
    Just(location) | is-redirect && redirects-left > 0 ->
      val next = u.resolve(location.trim)
      val to-get = res.status == 303 && method != "HEAD" || (res.status == 301 || res.status == 302) && method == "POST"
      val (method', body', hs1) = if to-get
        then ("GET", bytes/empty, headers.remove-headers(["Content-Type", "Content-Length", "Transfer-Encoding"]))
        else (method, body, headers)
      val hs2 = if same-origin(u, next) then hs1 else hs1.remove-headers(["Authorization", "Cookie"])
      follow-redirects(method', next, hs2, body', pretend-decreasing(redirects-left - 1), tls-ca)
    _ | is-redirect && res.header("Location").is-just ->
      throw("http: too many redirects (the last one was to " ++ res.header("Location").default("").show ++ ")")
    _ -> res

fun remove-headers( hs : headers, names : list<string> ) : headers
  val lnames = names.map(to-lower)
  hs.filter(fn((n, _)) !lnames.any(fn(l) l == n.to-lower))

fun same-origin( a : url, b : url ) : bool
  a.scheme == b.scheme && a.host.to-lower == b.host.to-lower && a.effective-port == b.effective-port

// Send one request (no redirects).
fun send-request( method : string, u : url, headers : headers, body : bytes, tls-ca : string ) : <async,exn,net> http-response
  if u.scheme != "http" && u.scheme != "https" then throw("http: unsupported url scheme " ++ u.scheme.show)
  val conn-port = u.effective-port.default(80)
  val target = (if u.path.is-empty then "/" else u.path) ++ (if u.has-query then "?" ++ u.query else "")
  val host-header = if u.port.is-just then u.host ++ ":" ++ conn-port.show else u.host
  val hs0 = headers.set-header("Host", host-header).set-header("Connection", "close")
  val hs = if hs0.header("User-Agent").is-just then hs0 else hs0.set-header("User-Agent", "koka-http")
  val s = if u.scheme == "https" then tls-connect(u.host, conn-port, ca = tls-ca) else plain-stream(tcp-connect(u.host, conn-port))
  with finally { s.close }
  write-message(s, method ++ " " ++ target ++ " HTTP/1.1", hs, body)
  read-response(Reader(s, bytes/empty), method)

fun read-response( r : reader, method : string ) : <async,exn> http-response
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
        val (res-body, _) = if no-body then (bytes/empty, r1) else r1.read-body(hs, True)
        Http-response(status, parts.drop(2).join(" "), hs, res-body)

// `GET` a URL.
pub fun http-get( url : string, headers : headers = [], max-redirects : int = 10, tls-ca : string = "" ) : <async,exn,net> http-response
  http-request("GET", url, headers, max-redirects = max-redirects, tls-ca = tls-ca)

// `POST` a body to a URL.
pub fun http-post( url : string, body : bytes, content-type : string = "application/octet-stream", headers : headers = [], max-redirects : int = 10, tls-ca : string = "" ) : <async,exn,net> http-response
  http-request("POST", url, headers.set-header("Content-Type", content-type), body, max-redirects, tls-ca)

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
pub fun http-serve( srv : tcp-server, on-request : http-request -> <async,exn,ndet|e> http-response, tls : maybe<tls-config> = Nothing ) : <async,exn,ndet|e> ()
  srv.serve fn(conn)
    match tls
      Nothing -> serve-connection(Reader(plain-stream(conn), bytes/empty), on-request)
      Just(config) ->
        val s = conn.tls-accept(config)
        serve-connection(Reader(s, bytes/empty), on-request)
        s.close-notify

fun serve-connection( r : reader, on-request : http-request -> <async,exn,ndet|e> http-response ) : <async,exn,ndet|e> ()
  match r.read-until(crlfcrlf, 64 * 1024)
    Nothing -> ()   // the client closed the connection
    Just((head-bytes, r1)) ->
      val lines = head-bytes.string.split("\r\n")
      val req-line = lines.head.default("").split(" ")
      match req-line
        [method, target, version] ->
          val hs = parse-headers(lines.drop(1))
          val (req-body, r2) = r1.read-body(hs, False)
          val req = Http-request(method, target, hs, req-body)
          val res = mask<exn>{ catch(fn(exn) text-response(500, "internal server error: " ++ exn.message), { on-request(req) }) }
          val keep-alive = match hs.header("Connection").map(to-lower)
            Just("close") -> False
            Just("keep-alive") -> True
            _ -> version == "HTTP/1.1"
          val res-headers = res.headers.set-header("Connection", if keep-alive then "keep-alive" else "close")
          val reason = if res.reason.is-empty then reason-phrase(res.status) else res.reason
          val res-body = if method == "HEAD" then bytes/empty else res.body
          write-message(r.sock, "HTTP/1.1 " ++ res.status.show ++ " " ++ reason, res-headers, res-body)
          if keep-alive then serve-connection(pretend-decreasing(r2), on-request)
        _ ->
          write-message(r.sock, "HTTP/1.1 400 Bad Request", [("Connection", "close")], "bad request".bytes)
