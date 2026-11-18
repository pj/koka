/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* WebSocket (RFC 6455) client and server, for `ws` and `wss`.

   A server answers a WebSocket request from its HTTP handler with
   `websocket-response`, which then runs a function on the connection:

   ```
   http-serve(server) fn(req)
     match req.path
       "/echo" -> websocket-response(req) fn(ws)
         ws.foreach fn(msg)
           ws.send(msg)
       _ -> text-response(404, "not found")
   ```

   A client connects with `websocket-connect`:

   ```
   with ws = websocket-connect("ws://127.0.0.1:8080/echo")
   ws.send-text("hello")
   println(ws.receive)      // Just(Text("hello"))
   ```

   Pings are answered automatically. Messages are received whole (fragmented
   messages are put together) and sent as a single frame. Text messages are
   checked to be valid UTF-8. A message larger than `max-message` bytes
   closes the connection with code 1009.

   One strand may receive while others send. The close handshake is done by
   `close` (and automatically when the server function or the scope of
   `websocket-connect` ends): `receive` returns `Nothing` once the other side
   closed, and `close-code` and `close-reason` then tell why.

   WebSockets over HTTP/2 (RFC 8441) are not supported; clients use
   HTTP/1.1 for them.
*/
module async/os/websocket

import std/core/undiv
import std/core/unsafe
import std/time/duration
import std/time/timer
import async/async
import async/interleave
import async/os/net
import async/os/tls
import async/os/http
import std/net/url
import std/text/encoding
import std/crypto/hash
import std/crypto/aes

// ----------------------------------------------------------------------------
// Connections and messages
// ----------------------------------------------------------------------------

// A message: text or binary data.
pub type ws-message
  Text( text : string )
  Binary( data : bytes )

pub fun ws-message/show( m : ws-message ) : string
  match m
    Text(t) -> "Text(" ++ t.show ++ ")"
    Binary(b) -> "Binary(" ++ b.length.show ++ " bytes)"

pub fun ws-message/(==)( a : ws-message, b : ws-message ) : bool
  match (a, b)
    (Text(x), Text(y)) -> x == y
    (Binary(x), Binary(y)) -> x.list == y.list
    _ -> False

// An open WebSocket connection.
abstract struct websocket
  conn : net-stream
  is-client : bool                        // clients mask their frames, servers do not
  subprotocol : string                    // the subprotocol both sides agreed on, or `""`
  max-message : int
  buf : ref<global,bytes>                 // received bytes not yet parsed
  close-sent : ref<global,bool>
  close-received : ref<global,maybe<(int, string)>>   // the code and reason of the close frame (1006: none, the connection ended)
  receiving : ref<global,bool>            // is a strand in `receive`?

fun get( r : ref<global,a> ) : a
  unsafe-total { !r }

fun put( r : ref<global,a>, x : a ) : ()
  unsafe-total { r := x }

fun new-websocket( conn : net-stream, is-client : bool, protocol : string, received : bytes, max-message : int ) : websocket
  unsafe-total
    Websocket(conn, is-client, protocol, max-message, ref(received), ref(False), ref(Nothing), ref(False))

// The subprotocol both sides agreed on, or `""` if none.
pub fun protocol( ws : websocket ) : string
  ws.subprotocol

// The status code of the close frame the other side sent (`1005` if it had
// none, `1006` if the connection ended without one), once it was received.
pub fun close-code( ws : websocket ) : maybe<int>
  ws.close-received.get.map(fst)

// The reason in the close frame the other side sent, once it was received.
pub fun close-reason( ws : websocket ) : maybe<string>
  ws.close-received.get.map(snd)

// Did the other side close the connection?
pub fun is-closed( ws : websocket ) : bool
  ws.close-received.get.is-just

// ----------------------------------------------------------------------------
// Frames
// ----------------------------------------------------------------------------

val op-continuation = 0
val op-text = 1
val op-binary = 2
val op-close = 8
val op-ping = 9
val op-pong = 10

// The default maximum size of a received message (16 MiB).
pub val default-max-message = 16 * 1024 * 1024

fun byte( b : bytes, i : int ) : int
  b.unsafe-index(i.ssize_t).int

// `data` xor-ed with the 4-byte `key` repeated.
fun apply-mask( data : bytes, key : bytes ) : bytes
  val n = data.length
  fun grow( k : bytes ) : bytes
    if k.length >= n then k else grow(pretend-decreasing(k ++ k))
  if n == 0 then data else xor-bytes(data, grow(key))

// The big-endian encoding of `x` in `n` bytes.
fun big-endian( x : int, n : int ) : list<int>
  list(1, n).map(fn(i) (x / (256 ^ (n - i))) % 256)

fun frame-bytes( opcode : int, payload : bytes, masked : bool ) : ndet bytes
  val n = payload.length
  val len-bytes = if n < 126 then [n + (if masked then 128 else 0)]
                  elif n < 65536 then Cons(126 + (if masked then 128 else 0), big-endian(n, 2))
                  else Cons(127 + (if masked then 128 else 0), big-endian(n, 8))
  val start = Cons(128 + opcode, len-bytes).vector.bytes
  if masked then
    val key = random-bytes(4)
    start ++ key ++ apply-mask(payload, key)
  else start ++ payload

fun write-frame( ws : websocket, opcode : int, payload : bytes ) : <async,exn,ndet> ()
  ws.conn.write-all(frame-bytes(opcode, payload, ws.is-client))

// Take `n` received bytes, reading more as needed; `Nothing` if the
// connection ends first.
fun take( ws : websocket, n : int ) : <async,exn> maybe<bytes>
  val b = ws.buf.get
  if b.length >= n then
    ws.buf.put(b.subbytes(n))
    Just(b.subbytes(0, n))
  else
    fun more( parts : list<bytes>, have : int ) : <async,exn> maybe<bytes>
      if have >= n then Just(parts.reverse.join)
      else
        val chunk = ws.conn.read
        if chunk.is-empty then Nothing
        else more(pretend-decreasing(Cons(chunk, parts)), have + chunk.length)
    match more([b], b.length)
      Nothing ->
        ws.buf.put(bytes/empty)
        Nothing
      Just(all) ->
        ws.buf.put(all.subbytes(n))
        Just(all.subbytes(0, n))

// A violation of the protocol by the other side: close the connection with
// `code` and raise an exception.
fun fail( ws : websocket, code : int, msg : string ) : <async,exn,ndet> a
  if !ws.close-sent.get then
    ws.close-sent.put(True)
    catch(fn(_) (), { ws.write-frame(op-close, (big-endian(code, 2).vector.bytes)) })
  ws.close-received.put(Just((1006, "")))
  ws.conn.close
  throw("websocket: " ++ msg)

value struct frame
  fin : bool
  opcode : int
  payload : bytes

// Read a frame; `Nothing` if the connection ends.
fun read-frame( ws : websocket ) : <async,exn,ndet> maybe<frame>
  match ws.take(2)
    Nothing -> Nothing
    Just(h) ->
      val b0 = h.byte(0)
      val b1 = h.byte(1)
      val fin = b0 >= 128
      val opcode = b0 % 16
      if (b0 / 16) % 8 != 0 then ws.fail(1002, "a frame uses reserved bits")
      val masked = b1 >= 128
      if masked == ws.is-client then
        ws.fail(1002, if masked then "the server masked a frame" else "the client sent an unmasked frame")
      val len7 = b1 % 128
      val len = if len7 < 126 then len7 else
        match ws.take(if len7 == 126 then 2 else 8)
          Nothing -> -1
          Just(lb) -> lb.list.foldl(0, fn(acc, x) acc * 256 + x)
      if len < 0 then Nothing
      elif opcode >= 8 && (len > 125 || !fin) then ws.fail(1002, "an invalid control frame")
      elif len > ws.max-message then ws.fail(1009, "a message is larger than " ++ ws.max-message.show ++ " bytes")
      else
        val key = if masked then ws.take(4) else Just(bytes/empty)
        match key
          Nothing -> Nothing
          Just(k) -> match ws.take(len)
            Nothing -> Nothing
            Just(p) -> Just(Frame(fin, opcode, if masked then apply-mask(p, k) else p))

// Is `b` valid UTF-8 (no overlong encodings, surrogates, or code points
// above U+10FFFF)?
pub fun is-valid-utf8( b : bytes ) : bool
  val n = b.length
  fun within( i : int, lo : int, hi : int ) : bool
    i < n && b.byte(i) >= lo && b.byte(i) <= hi
  fun go( i : int ) : bool
    if i >= n then True
    else
      val c = b.byte(i)
      if c < 0x80 then go(pretend-decreasing(i + 1))
      elif c < 0xC2 then False
      elif c < 0xE0 then within(i + 1, 0x80, 0xBF) && go(pretend-decreasing(i + 2))
      elif c < 0xF0 then
        val (lo, hi) = if c == 0xE0 then (0xA0, 0xBF) elif c == 0xED then (0x80, 0x9F) else (0x80, 0xBF)
        within(i + 1, lo, hi) && within(i + 2, 0x80, 0xBF) && go(pretend-decreasing(i + 3))
      elif c < 0xF5 then
        val (lo, hi) = if c == 0xF0 then (0x90, 0xBF) elif c == 0xF4 then (0x80, 0x8F) else (0x80, 0xBF)
        within(i + 1, lo, hi) && within(i + 2, 0x80, 0xBF) && within(i + 3, 0x80, 0xBF) && go(pretend-decreasing(i + 4))
      else False
  go(0)

fun is-valid-close-code( code : int ) : bool
  (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014) || (code >= 3000 && code <= 4999)

// ----------------------------------------------------------------------------
// Receiving and sending
// ----------------------------------------------------------------------------

// Receive the next message. Pings are answered while waiting. Returns
// `Nothing` when the other side closed the connection (a close frame is sent
// back; see `close-code`). Raises an exception if the other side breaks the
// protocol (after closing the connection with a fitting code).
pub fun receive( ws : websocket ) : <async,exn,ndet> maybe<ws-message>
  // `first`: the opcode of the message being received (0: none yet), with its fragments
  fun next( first : int, parts : list<bytes>, size : int ) : <async,exn,ndet> maybe<ws-message>
    if ws.is-closed then Nothing
    else match ws.read-frame
      Nothing ->
        ws.close-received.put(Just((1006, "")))
        Nothing
      Just(Frame(fin, opcode, payload)) ->
        if opcode == op-ping then
          if !ws.close-sent.get then ws.write-frame(op-pong, payload)
          next(pretend-decreasing(first), parts, size)
        elif opcode == op-pong then next(pretend-decreasing(first), parts, size)
        elif opcode == op-close then
          ws.on-close-frame(payload)
          Nothing
        elif opcode == op-continuation && first == 0 then ws.fail(1002, "a continuation frame without a message")
        elif (opcode == op-text || opcode == op-binary) && first != 0 then ws.fail(1002, "a new message inside a fragmented one")
        elif opcode != op-continuation && opcode != op-text && opcode != op-binary then ws.fail(1002, "an unknown opcode " ++ opcode.show)
        else
          val op = if first == 0 then opcode else first
          val total = size + payload.length
          if total > ws.max-message then ws.fail(1009, "a message is larger than " ++ ws.max-message.show ++ " bytes")
          elif !fin then next(pretend-decreasing(op), Cons(payload, parts), total)
          else
            val data = Cons(payload, parts).reverse.join
            if op == op-binary then Just(Binary(data))
            elif data.is-valid-utf8 then Just(Text(data.string))
            else ws.fail(1007, "a text message is not valid UTF-8")
  ws.receiving.put(True)
  with finally { ws.receiving.put(False) }
  next(0, [], 0)

// A close frame arrived: remember its code and reason, and answer it.
fun on-close-frame( ws : websocket, payload : bytes ) : <async,exn,ndet> ()
  val n = payload.length
  if n == 1 then ws.fail(1002, "a close frame with a 1-byte payload")
  val code = if n == 0 then 1005 else payload.byte(0) * 256 + payload.byte(1)
  if n >= 2 && !code.is-valid-close-code then ws.fail(1002, "an invalid close code " ++ code.show)
  val reason = if n > 2 then payload.subbytes(2) else bytes/empty
  if !reason.is-valid-utf8 then ws.fail(1007, "the reason in a close frame is not valid UTF-8")
  ws.close-received.put(Just((code, reason.string)))
  if !ws.close-sent.get then
    ws.close-sent.put(True)
    catch(fn(_) (), { ws.write-frame(op-close, if n == 0 then bytes/empty else payload.subbytes(0, 2)) })

// Receive messages until the other side closes the connection, calling `f` on each.
pub fun foreach( ws : websocket, f : ws-message -> <async,exn,ndet,div|e> () ) : <async,exn,ndet,div|e> ()
  match ws.receive
    Just(msg) ->
      f(msg)
      foreach(ws, f)
    Nothing -> ()

fun check-open( ws : websocket ) : exn ()
  if ws.close-sent.get then throw("websocket: the connection is closed")

// Send a message.
pub fun send( ws : websocket, msg : ws-message ) : <async,exn,ndet> ()
  ws.check-open
  match msg
    Text(t) -> ws.write-frame(op-text, t.bytes)
    Binary(b) -> ws.write-frame(op-binary, b)

// Send a text message.
pub fun send-text( ws : websocket, text : string ) : <async,exn,ndet> ()
  ws.send(Text(text))

// Send a binary message.
pub fun send-binary( ws : websocket, data : bytes ) : <async,exn,ndet> ()
  ws.send(Binary(data))

// Send a ping (with at most 125 bytes of data); the other side answers with
// a pong, which `receive` skips.
pub fun ping( ws : websocket, data : bytes = bytes/empty ) : <async,exn,ndet> ()
  ws.check-open
  if data.length > 125 then throw("websocket: ping data is longer than 125 bytes")
  ws.write-frame(op-ping, data)

// Close the connection: send a close frame with `code` and `reason` (unless
// one was sent already), wait (at most `wait`) for the other side's close
// frame (at most `grace`), skipping messages that still arrive, and close
// the connection. If another strand is in `receive`, that strand gets the
// close frame. Closing a closed connection does nothing.
pub fun close( ws : websocket, code : int = 1000, reason : string = "", grace : duration = 5.seconds ) : <async,ndet> ()
  if !ws.close-sent.get then
    ws.close-sent.put(True)
    val payload = big-endian(code, 2).vector.bytes ++ reason.bytes.subbytes(0, 123)
    catch(fn(_) (), { ws.write-frame(op-close, payload) })
  fun drain() : <async,exn,ndet,div> ()
    if ws.is-closed then ()
    elif ws.receiving.get then
      wait(20.milli-seconds)
      drain()
    else match ws.read-frame
      Just(Frame(_, opcode, payload)) ->
        if opcode == op-close then ws.on-close-frame(payload) else drain()
      Nothing -> ws.close-received.put(Just((1006, "")))
  catch(fn(_) (), { val _ = timeout(grace, { pretend-no-div { drain() } }); () })
  ws.conn.close

// ----------------------------------------------------------------------------
// Handshake
// ----------------------------------------------------------------------------

val ws-guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

fun accept-key( key : string ) : string
  base64-encode(sha1((key ++ ws-guid).bytes))

fun header-tokens( hs : headers, name : string ) : list<string>
  hs.filter(fn((n, _)) n.to-lower == name.to-lower).flatmap(fn((_, v)) v.split(",").map(fn(t) t.trim))

fun has-token( hs : headers, name : string, token : string ) : bool
  hs.header-tokens(name).any(fn(t) t.to-lower == token)

// Is `req` a request to open a WebSocket?
pub fun is-websocket-request( req : http-request ) : bool
  req.method == "GET" && req.http-request/headers.has-token("Upgrade", "websocket") && req.http-request/headers.has-token("Connection", "upgrade")

// The answer to a WebSocket request: when the handshake succeeds, `on-open`
// runs on the connection after the `101` response, and the connection is
// closed when it returns (with code 1011 if it raised an exception, which is
// then raised again). Otherwise it is an error response (`400`, or `426` for
// a request that is not a WebSocket request or uses another version).
//
// If the client asks for subprotocols, the first of its choices that is in
// `protocols` is chosen (see `protocol`).
pub fun websocket-response( req : http-request, on-open : websocket -> <async,exn,ndet,div> (), protocols : list<string> = [],
                            max-message : int = default-max-message, headers : headers = [] ) : http-response
  val key = req.header("Sec-WebSocket-Key").default("").trim
  if !is-websocket-request(req) then
    text-response(426, "a WebSocket request is expected", [("Upgrade", "websocket"), ("Connection", "Upgrade")])
  elif req.header("Sec-WebSocket-Version").map(trim) != Just("13") then
    text-response(426, "only WebSocket version 13 is supported", [("Sec-WebSocket-Version", "13")])
  elif base64-decode(key).map(length) != Just(16) then
    text-response(400, "invalid Sec-WebSocket-Key")
  else
    val chosen = req.http-request/headers.header-tokens("Sec-WebSocket-Protocol").find(fn(p) protocols.any(fn(q) q == p)).default("")
    val hs0 = headers.set-header("Sec-WebSocket-Accept", accept-key(key))
    val hs = if chosen.is-empty then hs0 else hs0.set-header("Sec-WebSocket-Protocol", chosen)
    upgrade-response("websocket", fn(conn, received) {
      val ws = new-websocket(conn, False, chosen, received, max-message)
      match try(fn() on-open(ws))
        Ok -> ws.close
        Error(exn) ->
          ws.close(1011)
          throw-exn(exn)
    }, hs)

// Connect to a WebSocket server at `url` (`ws://` or `wss://`). `protocols`
// are offered to the server (see `protocol` for the one it chose), and
// `headers` are added to the request. For `wss`, `tls-ca`, `tls-cert` and
// `tls-key` are as for `http-request`. Raises an exception if the server
// does not accept the connection.
pub fun websocket-connect( url : string, protocols : list<string> = [], headers : headers = [], max-message : int = default-max-message,
                           tls-ca : string = "", tls-cert : string = "", tls-key : string = "" ) : <async,exn,net,ndet> websocket
  val u = match parse-url(url)
    Just(u) -> u
    Nothing -> throw("websocket: invalid url " ++ url.show)
  val secure = match u.scheme
    "ws" -> False
    "http" -> False
    "wss" -> True
    "https" -> True
    s -> throw("websocket: unsupported url scheme " ++ s.show)
  val conn-port = u.effective-port.default(if secure then 443 else 80)
  val target = (if u.path.is-empty then "/" else u.path) ++ (if u.has-query then "?" ++ u.query else "")
  val host-header = if u.port.is-just then u.host ++ ":" ++ conn-port.show else u.host
  val key = base64-encode(random-bytes(16))
  val hs0 = headers.set-header("Host", host-header).set-header("Upgrade", "websocket").set-header("Connection", "Upgrade")
                   .set-header("Sec-WebSocket-Key", key).set-header("Sec-WebSocket-Version", "13")
  val hs = if protocols.is-nil then hs0 else hs0.set-header("Sec-WebSocket-Protocol", protocols.join(", "))
  val conn = if secure then tls-connect(u.host, conn-port, ca = tls-ca, cert = tls-cert, key = tls-key)
             else plain-stream(tcp-connect(u.host, conn-port))
  match try(fn() handshake(conn, target, hs, key, protocols, max-message))
    Ok(ws) -> ws
    Error(exn) ->
      conn.close
      throw-exn(exn)

// Connect to a WebSocket server (see `websocket-connect`), run `action`, and
// close the connection afterwards.
pub fun scoped/websocket-connect( url : string, action : websocket -> <async,exn,net,ndet|e> a, protocols : list<string> = [], headers : headers = [],
                                  max-message : int = default-max-message, tls-ca : string = "", tls-cert : string = "", tls-key : string = "" ) : <async,exn,net,ndet|e> a
  val ws = websocket-connect(url, protocols, headers, max-message, tls-ca, tls-cert, tls-key)
  with finally { ws.close }
  action(ws)

fun handshake( conn : net-stream, target : string, hs : headers, key : string, protocols : list<string>, max-message : int ) : <async,exn> websocket
  conn.write-all(("GET " ++ target ++ " HTTP/1.1\r\n" ++ hs.map(fn((n, v)) n ++ ": " ++ v ++ "\r\n").join ++ "\r\n").bytes)
  val (head-bytes, rest) = read-head(conn, bytes/empty)
  val lines = head-bytes.string.split("\r\n")
  val status-line = lines.head.default("")
  val status = status-line.split(" ").drop(1).head.default("")
  val rhs = lines.drop(1).filter(fn(l) !l.is-empty).map fn(l)
    match l.find(":")
      Just(sl) -> (sl.before.string.trim, sl.after.string.trim)
      Nothing -> throw("websocket: invalid header line " ++ l.show)
  if status != "101" then throw("websocket: the server answered " ++ status-line.show ++ " instead of switching protocols")
  if !rhs.has-token("Upgrade", "websocket") || !rhs.has-token("Connection", "upgrade") then
    throw("websocket: the server did not switch to the WebSocket protocol")
  if rhs.header("Sec-WebSocket-Accept").map(trim) != Just(accept-key(key)) then
    throw("websocket: the server sent a wrong Sec-WebSocket-Accept")
  val chosen = rhs.header("Sec-WebSocket-Protocol").default("").trim
  if !chosen.is-empty && !protocols.any(fn(p) p == chosen) then
    throw("websocket: the server chose a subprotocol that was not offered: " ++ chosen.show)
  new-websocket(conn, True, chosen, rest, max-message)

// Read the response head (up to the empty line), and the bytes after it.
fun read-head( conn : net-stream, acc : bytes ) : <async,exn> (bytes, bytes)
  match find-crlfcrlf(acc, 0)
    Just(i) -> (acc.subbytes(0, i), acc.subbytes(i + 4))
    Nothing ->
      if acc.length > 64 * 1024 then throw("websocket: the response head is too large")
      val more = conn.read
      if more.is-empty then throw("websocket: the connection closed during the handshake")
      read-head(conn, pretend-decreasing(acc ++ more))

fun find-crlfcrlf( b : bytes, i : int ) : maybe<int>
  if i + 4 > b.length then Nothing
  elif b.byte(i) == 13 && b.byte(i + 1) == 10 && b.byte(i + 2) == 13 && b.byte(i + 3) == 10 then Just(i)
  else find-crlfcrlf(b, pretend-decreasing(i + 1))
