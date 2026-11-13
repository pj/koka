/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* HTTP/2 connections ([RFC 9113](https://www.rfc-editor.org/rfc/rfc9113)).

   This module implements the protocol: framing, header compression (with
   `std/net/hpack`), stream multiplexing, and flow control. It is used by
   `std/async/os/http`, which selects HTTP/2 with ALPN (`https`) or with prior
   knowledge (`h2c`); use that module instead of this one.

   A client connection has no reader of its own: a request that waits for its
   response reads frames for all streams of the connection until its own
   response is complete, and then hands the reading over to another waiting
   request. A server connection has a reader strand and a pool of strands
   that run the request handlers. A request is handed to a handler when its
   headers arrive, with its body as a stream of the DATA frames; the stream's
   flow control window is given back as the handler reads the body, so a slow
   handler slows down the client.

   Not supported: server push (disabled with `SETTINGS_ENABLE_PUSH`), stream
   priorities (ignored), and the HTTP/1.1 `Upgrade: h2c` mechanism.
*/
module async/os/http2

import std/core/undiv
import std/core/unsafe
import std/time/duration
import std/time/timer
import async/async
import async/internal
import async/channel
import async/interleave
import async/os/tls
import std/net/hpack

// A header list: names are lower case; pseudo headers (`:status` etc.) come first.
pub alias h2-headers = list<(string, string)>

// The body of a response from a server: all at once, or produced in parts by a
// writer that calls `write` with each part (sent as it is produced).
pub type h2-body
  H2-bytes( bytes : bytes )
  H2-writer( writer : (write : bytes -> <async,exn> ()) -> <async,exn,ndet,div> () )

// A server's request handler: it gets the request headers and the body as a
// stream, and returns `(status, headers, body)`.
pub alias h2-handler<e> = (h2-headers, seq<<async,exn,ndet|e>,bytes>) -> <async,exn,ndet|e> (int, list<(string, string)>, h2-body)

// ----------------------------------------------------------------------------
// Frames
// ----------------------------------------------------------------------------

val frame-data          = 0
val frame-headers       = 1
val frame-priority      = 2
val frame-rst-stream    = 3
val frame-settings      = 4
val frame-push-promise  = 5
val frame-ping          = 6
val frame-goaway        = 7
val frame-window-update = 8
val frame-continuation  = 9

val flag-end-stream  = 1
val flag-ack         = 1
val flag-end-headers = 4
val flag-padded      = 8
val flag-priority    = 32

val err-no-error       = 0
val err-protocol       = 1
val err-internal       = 2
val err-flow-control   = 3
val err-stream-closed  = 5
val err-frame-size     = 6
val err-refused-stream = 7
val err-cancel         = 8
val err-compression    = 9

val default-window   = 65535
val our-window       = 1048576    // the stream and connection receive windows we announce
val max-frame-size   = 16384      // we accept frames up to the default maximum size
val max-header-block = 262144
val server-max-streams = 100
val server-workers     = 16

val client-preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

value struct frame
  ftype : int
  flags : int
  sid : int
  payload : bytes

fun has-flag( flags : int, flag : int ) : bool
  (flags / flag) % 2 == 1

fun byte-at( b : bytes, i : int ) : int
  b.unsafe-index(i.ssize_t).int

fun be16( b : bytes, i : int ) : int
  b.byte-at(i) * 256 + b.byte-at(i + 1)

fun be24( b : bytes, i : int ) : int
  b.byte-at(i) * 65536 + b.be16(i + 1)

fun be32( b : bytes, i : int ) : int
  b.be16(i) * 65536 + b.be16(i + 2)

fun put16( n : int ) : list<int>
  [(n / 256) % 256, n % 256]

fun put32( n : int ) : list<int>
  put16(n / 65536) ++ put16(n % 65536)

fun frame-bytes( ftype : int, flags : int, sid : int, payload : bytes ) : bytes
  val len = payload.length
  ([(len / 65536) % 256, (len / 256) % 256, len % 256, ftype, flags] ++ put32(sid)).vector.bytes ++ payload

fun settings-frame( settings : list<(int, int)> ) : bytes
  frame-bytes(frame-settings, 0, 0, settings.flatmap(fn((id, value)) put16(id) ++ put32(value)).vector.bytes)

fun window-update( sid : int, increment : int ) : bytes
  frame-bytes(frame-window-update, 0, sid, put32(increment).vector.bytes)

fun rst-stream( sid : int, code : int ) : bytes
  frame-bytes(frame-rst-stream, 0, sid, put32(code).vector.bytes)

fun goaway( last-sid : int, code : int ) : bytes
  frame-bytes(frame-goaway, 0, 0, (put32(last-sid) ++ put32(code)).vector.bytes)

// HEADERS followed by CONTINUATION frames if the block is larger than `max-frame`.
fun header-frames( sid : int, block : bytes, end-stream : bool, max-frame : int ) : bytes
  val es = if end-stream then flag-end-stream else 0
  if block.length <= max-frame then frame-bytes(frame-headers, es + flag-end-headers, sid, block)
  else
    fun rest( pos : int ) : list<bytes>
      if pos >= block.length then []
      else
        val n = min(max-frame, block.length - pos)
        val last = pos + n >= block.length
        Cons(frame-bytes(frame-continuation, if last then flag-end-headers else 0, sid, block.subbytes(pos, n)), rest(pretend-decreasing(pos + n)))
    Cons(frame-bytes(frame-headers, es, sid, block.subbytes(0, max-frame)), rest(max-frame)).join

// Remove the padding (and the priority fields of HEADERS) from a payload.
fun frame-content( f : frame ) : exn bytes
  val p = f.payload
  val (pad, start) = if f.flags.has-flag(flag-padded) then
                       (if p.is-empty then throw-h2(err-protocol, "padding without a length") else (p.byte-at(0), 1))
                     else (0, 0)
  val start' = if f.ftype == frame-headers && f.flags.has-flag(flag-priority) then start + 5 else start
  if start' + pad > p.length then throw-h2(err-protocol, "invalid padding")
  p.subbytes(start', p.length - start' - pad)

// ----------------------------------------------------------------------------
// Errors
// ----------------------------------------------------------------------------

// A connection error: the code is sent with GOAWAY.
extend type exception-info
  H2-error( code : int )

fun throw-h2( code : int, msg : string ) : exn a
  throw("http2: " ++ msg, H2-error(code))

fun h2-code( e : exception ) : int
  match e.info
    H2-error(code) -> code
    _ -> err-internal

// ----------------------------------------------------------------------------
// Connection state
// ----------------------------------------------------------------------------

struct h2stream
  s-sid : int
  s-ch : channel<()>          // notified when anything about the stream changes
  s-headers : h2-headers      // the received header list (request on a server, response on a client)
  s-has-headers : bool
  s-body : list<bytes>        // received data, newest first
  s-done : bool               // the peer ended the stream
  s-reset : int               // the RST_STREAM code, or -1
  s-window : int              // what we may still send on the stream
  s-streaming : bool          // client: the body is read as a stream (its window is given back as it is read)

struct h2state
  c-buf : bytes               // received bytes that are not yet a complete frame
  c-decoder : hpack-decoder
  c-streams : list<h2stream>
  c-next-sid : int            // client: the next stream id
  c-last-sid : int            // server: the highest stream id opened by the client
  c-window : int              // what we may still send on the connection
  c-init-window : int         // the peer's initial stream window
  c-max-frame : int           // the peer's maximum frame size
  c-max-streams : int         // the peer's maximum number of concurrent streams
  c-closed : bool             // no new streams (GOAWAY sent or received, or the connection failed)
  c-goaway-last : int         // after a GOAWAY from the peer: the last stream it processes
  c-error : string            // why the connection failed, if it did
  c-reading : bool            // client: a request is reading frames
  c-pending : maybe<(int, int, bytes)>   // a header block awaiting CONTINUATION: (stream, flags, fragment)
  c-waiters : list<channel<()>>          // notified on the next change (waiting for a free stream)
  c-last-used : int           // milliseconds (`ticks`)

// An HTTP/2 connection.
abstract struct h2conn
  sock : net-stream
  is-client : bool
  state : ref<global,h2state>
  queue : channel<maybe<int>>   // server: streams with a complete request; `Nothing` stops a worker

// (signatures are needed: inferring the effect of reading the ref fails)
fun get-state( r : ref<global,h2state> ) : <read<global>,div> h2state
  !r

fun set-state( c : h2conn, st : h2state ) : <write<global>,div> ()
  val r = c.state
  r := st

fun now-ms() : async int
  async-ioc { ticks().milli-seconds }

fun notify-all( st : h2state ) : ioc h2state
  st.c-streams.foreach(fn(s) emit-io(s.s-ch, ()))
  st.c-waiters.foreach(fn(w) emit-io(w, ()))
  st(c-waiters = [])

fun find-stream( st : h2state, sid : int ) : maybe<h2stream>
  st.c-streams.find(fn(s) s.s-sid == sid)

fun update-stream( st : h2state, sid : int, f : h2stream -> h2stream ) : h2state
  st(c-streams = st.c-streams.map(fn(s) if s.s-sid == sid then f(s) else s))

fun new-state( buf : bytes, is-client : bool, now : int ) : h2state
  H2state(buf, hpack-decoder(), [], if is-client then 1 else 2, 0, default-window, default-window, max-frame-size,
          if is-client then 100 else 1000000, False, 0, "", False, Nothing, [], now)

fun send( c : h2conn, data : bytes ) : <async,exn> ()
  c.sock.write-all(data)

// Send without waiting for the write: used while processing received frames,
// so that a reader never blocks on a full send buffer (both peers would stop
// reading while they wait to write).
fun send-queued( c : h2conn, data : bytes ) : <async,exn> ()
  c.sock.write-queued(data)

// Mark the connection as failed and wake up everyone.
fun fail( c : h2conn, msg : string ) : async ()
  async-ioc
    val st = get-state(c.state)
    set-state(c, notify-all(st(c-closed = True, c-error = if st.c-error.is-empty then msg else st.c-error)))

// Fail the connection with a GOAWAY and close the socket.
fun fail-with( c : h2conn, code : int, msg : string ) : async ()
  c.fail(msg)
  val last = async-ioc { get-state(c.state).c-last-sid }
  catch(fn(_) (), { c.send(goaway(last, code)) })
  c.sock.close

// ----------------------------------------------------------------------------
// Reading and processing frames
// ----------------------------------------------------------------------------

// Read the next frame; `Nothing` at the end of the stream.
fun read-frame( c : h2conn ) : <async,exn> maybe<frame>
  val buf = async-ioc { get-state(c.state).c-buf }
  if buf.length >= 9 then
    val len = buf.be24(0)
    if len > max-frame-size then throw-h2(err-frame-size, "frame too large (" ++ len.show ++ " bytes)")
    if buf.length >= 9 + len then
      val f = Frame(buf.byte-at(3), buf.byte-at(4), buf.be32(5) % 2147483648, buf.subbytes(9, len))
      async-ioc { set-state(c, get-state(c.state)(c-buf = buf.subbytes(9 + len))) }
      return Just(f)
  val more = c.sock.read
  if more.is-empty then Nothing
  else
    async-ioc
      val st = get-state(c.state)
      set-state(c, st(c-buf = st.c-buf ++ more))
    read-frame(pretend-decreasing(c))

// Read and process one frame. Connection errors fail the connection (and
// are not raised). Returns `False` once the connection is closed.
fun read-one( c : h2conn ) : <async,ndet> bool
  val res = catch(fn(e) Error(e), { Ok(c.read-frame) })
  match res
    Ok(Just(f)) ->
      match catch(fn(e) Just(e), { c.process(f); Nothing })
        Nothing ->
          val finished = async-ioc
            val st = get-state(c.state)
            st.c-closed && st.c-streams.is-empty
          !finished
        Just(e) ->
          c.fail-with(e.h2-code, e.message)
          False
    Ok(Nothing) ->
      c.fail("http2: connection closed by the peer")
      False
    Error(e) ->
      c.fail-with(e.h2-code, e.message)
      False

fun process( c : h2conn, f : frame ) : <async,exn,ndet> ()
  // a header block must be continued before any other frame
  val pending = async-ioc { get-state(c.state).c-pending }
  match pending
    Just((psid, _, _)) | f.ftype != frame-continuation || f.sid != psid ->
      throw-h2(err-protocol, "expected CONTINUATION")
    _ -> ()
  if f.ftype == frame-data then c.on-data(f)
  elif f.ftype == frame-headers then
    if f.sid == 0 then throw-h2(err-protocol, "HEADERS on stream 0")
    c.on-header-fragment(f.sid, f.flags, f.frame-content)
  elif f.ftype == frame-continuation then
    match pending
      Just((psid, pflags, fragment)) ->
        async-ioc { set-state(c, get-state(c.state)(c-pending = Nothing)) }
        c.on-header-fragment(psid, pflags + (if f.flags.has-flag(flag-end-headers) then flag-end-headers else 0), fragment ++ f.payload)
      Nothing -> throw-h2(err-protocol, "unexpected CONTINUATION")
  elif f.ftype == frame-rst-stream then
    if f.payload.length != 4 then throw-h2(err-frame-size, "invalid RST_STREAM")
    val code = f.payload.be32(0)
    async-ioc
      val st = get-state(c.state)
      match st.find-stream(f.sid)
        Just(s) ->
          emit-io(s.s-ch, ())
          set-state(c, st.update-stream(f.sid, fn(x) x(s-reset = code)))
        Nothing -> ()
  elif f.ftype == frame-settings then c.on-settings(f)
  elif f.ftype == frame-ping then
    if f.payload.length != 8 then throw-h2(err-frame-size, "invalid PING")
    if !f.flags.has-flag(flag-ack) then c.send-queued(frame-bytes(frame-ping, flag-ack, 0, f.payload))
  elif f.ftype == frame-goaway then
    if f.payload.length < 8 then throw-h2(err-frame-size, "invalid GOAWAY")
    val last = f.payload.be32(0) % 2147483648
    async-ioc
      val st = get-state(c.state)
      // streams the peer will not process are refused (and may be retried)
      val st1 = st(c-closed = True, c-goaway-last = last,
                   c-streams = st.c-streams.map(fn(s) if s.s-sid > last && !s.s-done then s(s-reset = err-refused-stream) else s))
      set-state(c, notify-all(st1))
  elif f.ftype == frame-window-update then
    if f.payload.length != 4 then throw-h2(err-frame-size, "invalid WINDOW_UPDATE")
    val inc = f.payload.be32(0) % 2147483648
    if inc == 0 && f.sid == 0 then throw-h2(err-protocol, "zero WINDOW_UPDATE")
    async-ioc
      val st = get-state(c.state)
      val st1 = if f.sid == 0 then st(c-window = st.c-window + inc)
                else st.update-stream(f.sid, fn(s) s(s-window = s.s-window + inc))
      set-state(c, notify-all(st1))
  elif f.ftype == frame-push-promise then throw-h2(err-protocol, "PUSH_PROMISE (push is disabled)")
  else ()   // PRIORITY and unknown frame types are ignored

fun on-settings( c : h2conn, f : frame ) : <async,exn> ()
  if f.flags.has-flag(flag-ack) then return ()
  if f.sid != 0 || f.payload.length % 6 != 0 then throw-h2(err-frame-size, "invalid SETTINGS")
  fun apply( st : h2state, pos : int ) : exn h2state
    if pos >= f.payload.length then st
    else
      val id = f.payload.be16(pos)
      val value = f.payload.be32(pos + 2)
      val st1 = if id == 3 then st(c-max-streams = value)
                elif id == 4 then
                  if value > 2147483647 then throw-h2(err-flow-control, "initial window too large")
                  val delta = value - st.c-init-window
                  st(c-init-window = value, c-streams = st.c-streams.map(fn(s) s(s-window = s.s-window + delta)))
                elif id == 5 then
                  if value < 16384 || value > 16777215 then throw-h2(err-protocol, "invalid maximum frame size")
                  st(c-max-frame = value)
                else st   // header table size (our encoder does not use the table), push, header list size
      apply(st1, pretend-decreasing(pos + 6))
  val st = async-ioc { get-state(c.state) }
  val st1 = apply(st, 0)
  async-ioc { set-state(c, notify-all(st1)) }
  c.send-queued(frame-bytes(frame-settings, flag-ack, 0, bytes/empty))

fun on-data( c : h2conn, f : frame ) : <async,exn> ()
  if f.sid == 0 then throw-h2(err-protocol, "DATA on stream 0")
  val data = f.frame-content
  val end-stream = f.flags.has-flag(flag-end-stream)
  val collect = async-ioc
    val st = get-state(c.state)
    match st.find-stream(f.sid)
      Just(s) ->
        emit-io(s.s-ch, ())
        val s1 = s(s-body = if data.is-empty then s.s-body else Cons(data, s.s-body), s-done = s.s-done || end-stream)
        set-state(c, st.update-stream(f.sid, fn(_) s1))
        c.is-client && !s.s-streaming
      Nothing -> False
  // give the connection window back right away; the stream window too on a
  // client that collects the body, while a server, or a client that streams
  // the body, gives it back as the body is read (see `stream-body`)
  val len = f.payload.length
  if len > 0 then
    c.send-queued(window-update(0, len) ++ (if collect && !end-stream then window-update(f.sid, len) else bytes/empty))

fun on-header-fragment( c : h2conn, sid : int, flags : int, fragment : bytes ) : <async,exn,ndet> ()
  if fragment.length > max-header-block then throw-h2(err-protocol, "header block too large")
  if !flags.has-flag(flag-end-headers) then
    async-ioc { set-state(c, get-state(c.state)(c-pending = Just((sid, flags, fragment)))) }
  else
    // decode in order (the decoder has state), even for streams that are gone
    val decoder = async-ioc { get-state(c.state).c-decoder }
    val (hs, decoder') = match catch(fn(e) Error(e), { Ok(decoder.decode(fragment)) })
      Ok(r) -> r
      Error(e) -> throw-h2(err-compression, e.message)
    async-ioc { set-state(c, get-state(c.state)(c-decoder = decoder')) }
    val end-stream = flags.has-flag(flag-end-stream)
    if c.is-client then c.on-response-headers(sid, hs, end-stream)
    else c.on-request-headers(sid, hs, end-stream)

fun on-response-headers( c : h2conn, sid : int, hs : h2-headers, end-stream : bool ) : <async,exn> ()
  val informational = match hs.lookup(fn(n) n == ":status")
    Just(st) -> st.starts-with("1").is-just
    Nothing -> False
  async-ioc
    val st = get-state(c.state)
    match st.find-stream(sid)
      Just(s) ->
        emit-io(s.s-ch, ())
        val s1 = if informational then s
                 elif s.s-has-headers then s(s-done = s.s-done || end-stream)   // trailers are ignored
                 else s(s-headers = hs, s-has-headers = True, s-done = end-stream)
        set-state(c, st.update-stream(sid, fn(_) s1))
      Nothing -> ()

fun on-request-headers( c : h2conn, sid : int, hs : h2-headers, end-stream : bool ) : <async,exn,ndet> ()
  val existing = async-ioc { get-state(c.state).find-stream(sid) }
  match existing
    Just(_) ->   // trailers
      async-ioc
        val st = get-state(c.state)
        val st1 = st.update-stream(sid, fn(s) s(s-done = s.s-done || end-stream))
        st.find-stream(sid).foreach(fn(s) emit-io(s.s-ch, ()))
        set-state(c, st1)
    Nothing ->
      val (last, active, closed) = async-ioc
        val st = get-state(c.state)
        (st.c-last-sid, st.c-streams.length, st.c-closed)
      if sid % 2 == 0 || sid <= last then throw-h2(err-protocol, "invalid stream id " ++ sid.show)
      if closed || active >= server-max-streams then
        async-ioc { set-state(c, get-state(c.state)(c-last-sid = sid)) }
        c.send-queued(rst-stream(sid, err-refused-stream))
      else
        val ch = channel()
        async-ioc
          val st = get-state(c.state)
          val s = H2stream(sid, ch, hs, True, [], end-stream, -1, st.c-init-window, False)
          set-state(c, st(c-last-sid = sid, c-streams = st.c-streams ++ [s]))
        c.queue.emit(Just(sid))

// ----------------------------------------------------------------------------
// Sending
// ----------------------------------------------------------------------------

// Wait until something changes for a stream (`ch` is its channel). On a
// client, the waiting request reads a frame itself if nobody else is reading.
fun wait-for( c : h2conn, ch : channel<()> ) : <async,ndet> ()
  if c.is-client then
    val lead = async-ioc
      val st = get-state(c.state)
      if st.c-reading || (st.c-closed && !st.c-error.is-empty) then False
      else
        set-state(c, st(c-reading = True))
        True
    if lead then
      with finally
        async-ioc
          val st = get-state(c.state)
          set-state(c, notify-all(st(c-reading = False)))
      val _ = c.read-one
      ()
    else ch.receive
  else ch.receive

fun check-stream( c : h2conn, sid : int ) : <async,exn> h2stream
  val (s, err) = async-ioc
    val st = get-state(c.state)
    (st.find-stream(sid), st.c-error)
  match s
    Just(x) | x.s-reset < 0 && err.is-empty -> x
    Just(x) | x.s-reset >= 0 -> throw("http2: stream reset by the peer (error " ++ x.s-reset.show ++ ")")
    _ -> throw(if err.is-empty then "http2: the stream was closed" else err)

// Client: did the server send a complete response and then reset the stream
// with `NO_ERROR`? Then it does not need the rest of the request body, which
// is not sent (RFC 9113 section 8.1).
fun answered-early( c : h2conn, sid : int ) : async bool
  c.is-client && async-ioc
    match get-state(c.state).find-stream(sid)
      Just(x) -> x.s-reset == err-no-error && x.s-has-headers && x.s-done
      Nothing -> False

// Send a body as DATA frames, respecting the flow control windows.
// A client sends the body while another strand awaits the response on the
// stream channel `ch` (see `h2-request`), so here it waits for more window on
// a channel of its own, registered as a waiter.
fun send-body( c : h2conn, sid : int, ch : channel<()>, body : bytes, end-stream : bool ) : <async,exn,ndet> ()
  val wch : channel<()> = if c.is-client then channel() else ch
  fun go( pos : int ) : <async,exn,ndet> ()
    if pos >= body.length || c.answered-early(sid) then ()
    else
      val s = c.check-stream(sid)
      val n = async-ioc
        val st = get-state(c.state)
        val k = min(body.length - pos, min(st.c-window, min(s.s-window, st.c-max-frame)))
        if k > 0 then
          set-state(c, st(c-window = st.c-window - k).update-stream(sid, fn(x) x(s-window = x.s-window - k)))
        elif c.is-client then
          set-state(c, st(c-waiters = Cons(wch, st.c-waiters)))
        k
      if n <= 0 then
        c.wait-for(wch)
        go(pretend-decreasing(pos))
      else
        val last = pos + n >= body.length
        c.send(frame-bytes(frame-data, if last && end-stream then flag-end-stream else 0, sid, body.subbytes(pos, n)))
        go(pretend-decreasing(pos + n))
  go(0)

// Send a header list (and a body) on a stream.
fun send-message( c : h2conn, sid : int, ch : channel<()>, hs : h2-headers, body : bytes ) : <async,exn,ndet> ()
  val max-frame = async-ioc { get-state(c.state).c-max-frame }
  c.send(header-frames(sid, hpack-encode(hs), body.is-empty, max-frame))
  if !body.is-empty then c.send-body(sid, ch, body, True)

// Headers that are specific to HTTP/1 connections are not allowed in HTTP/2.
pub fun h2-filter-headers( hs : list<(string, string)> ) : h2-headers
  hs.map(fn((n, v)) (n.to-lower, v)).filter fn((n, v))
    n != "connection" && n != "keep-alive" && n != "proxy-connection" && n != "transfer-encoding" &&
    n != "upgrade" && n != "host" && (n != "te" || v.to-lower == "trailers")

// ----------------------------------------------------------------------------
// Client
// ----------------------------------------------------------------------------

// Start a client connection on a stream (after ALPN chose `h2`, or with prior knowledge).
pub fun h2-connect( s : net-stream ) : <async,exn> h2conn
  val now = now-ms()
  val st : ref<global,h2state> = async-ioc { ref(new-state(bytes/empty, True, now)) }
  val q = channel()
  val c = H2conn(s, True, st, q)
  c.send(client-preface.bytes ++ settings-frame([(2, 0), (4, our-window)]) ++ window-update(0, our-window - default-window))
  c

// Can new requests be sent on the connection?
pub fun h2-is-open( c : h2conn ) : async bool
  async-ioc
    val st = get-state(c.state)
    !st.c-closed && st.c-next-sid < 2147483000

// The number of requests in progress.
pub fun h2-active( c : h2conn ) : async int
  async-ioc { get-state(c.state).c-streams.length }

// Are these the same connection?
pub fun h2-same( a : h2conn, b : h2conn ) : bool
  unsafe-ptr-eq(a.state, b.state)

// When the connection was last used (`ticks`, in milliseconds).
pub fun h2-last-used( c : h2conn ) : async int
  async-ioc { get-state(c.state).c-last-used }

// Close the connection (with a GOAWAY); requests in progress fail.
pub fun h2-close( c : h2conn ) : async ()
  val was-closed = async-ioc { get-state(c.state).c-error.is-empty.not }
  c.fail("http2: connection closed")
  if !was-closed then catch(fn(_) (), { c.send(goaway(0, err-no-error)) })
  c.sock.close

// Send a request and wait for the response: `(status, headers, body)`.
// Returns `Nothing` if the server refused the request without processing it
// (so it can be retried on another connection).
pub fun h2-request( c : h2conn, method : string, scheme : string, authority : string, path : string,
                    headers : list<(string, string)>, body : bytes ) : <async,exn,ndet> maybe<(int, h2-headers, bytes)>
  val ch = channel()
  val hs = [(":method", method), (":scheme", scheme), (":authority", authority), (":path", path)] ++ headers.h2-filter-headers
  val (sid, frames, alone) = c.open-stream(ch, hpack-encode(hs), body.is-empty, False, 0)
  with finally { c.close-stream(sid) }
  // if the request cannot even be sent, the connection was closed (for example
  // by an idle timeout of the server) and the request can be retried
  val sent = catch(fn(_) False, { c.send(frames); True })
  if !sent then
    c.fail("http2: the connection was closed")
    Nothing
  else
    val res = catch(fn(e) Error(e)) {
      if body.is-empty then Ok(c.await-response(sid, ch))
      else
        // read the response while the body is sent: a server that streams its
        // answer back while it reads the body otherwise blocks writing it once
        // the socket buffers are full, and stops reading the body (a deadlock
        // with the small loopback buffers on Windows)
        val (_, r) = interleaved({ c.send-body(sid, ch, body, True) }, { c.await-response(sid, ch) })
        Ok(r)
    }
    match res
      Ok(r) -> r
      Error(e) ->
        if c.unprocessed(sid, alone) then
          c.fail("http2: the connection was closed: " ++ e.message)
          Nothing
        else throw-exn(e)

// Open a stream: wait for a free stream if the peer limits them. The stream
// id is taken and the header frames are made without an await in between, so
// streams are opened in order (the caller sends the frames right away).
// Returns the stream id, the header frames, and whether no other stream was open.
fun open-stream( c : h2conn, ch : channel<()>, block : bytes, end-stream : bool, streaming : bool, round : int ) : <async,exn,ndet> (int, bytes, bool)
  val now = now-ms()
  val res = async-ioc
    val st = get-state(c.state)
    if st.c-closed then Left(if st.c-error.is-empty then "http2: the connection is closing" else st.c-error)
    elif st.c-streams.length >= st.c-max-streams then
      set-state(c, st(c-waiters = Cons(ch, st.c-waiters)))
      Right(Nothing)
    else
      val sid = st.c-next-sid
      val s = H2stream(sid, ch, [], False, [], False, -1, st.c-init-window, streaming)
      set-state(c, st(c-next-sid = sid + 2, c-streams = st.c-streams ++ [s], c-last-used = now))
      Right(Just((sid, header-frames(sid, block, end-stream, st.c-max-frame), st.c-streams.is-empty)))
  match res
    Left(msg) -> throw(msg)
    Right(Just(x)) -> x
    Right(Nothing) ->
      c.wait-for(ch)
      c.open-stream(ch, block, end-stream, streaming, pretend-decreasing(round + 1))

// Forget a client stream; reset it if it is still open.
fun close-stream( c : h2conn, sid : int ) : async ()
  val unfinished = async-ioc
    val st = get-state(c.state)
    val s = st.find-stream(sid)
    set-state(c, notify-all(st(c-streams = st.c-streams.filter(fn(x) x.s-sid != sid))))
    match s
      Just(x) -> !x.s-done && x.s-reset < 0 && !st.c-closed
      Nothing -> False
  if unfinished then catch(fn(_) (), { c.send(rst-stream(sid, err-cancel)) })

// Was a request that failed with an exception never processed by the server?
// A server closes an idle connection only when it has no streams, so a
// request that was alone on the connection and got no answer was not
// processed: it can be retried, as for a refused stream. (The GOAWAY is not
// always seen: on Windows a reset discards the data not yet read.)
fun unprocessed( c : h2conn, sid : int, alone : bool ) : async bool
  alone && async-ioc
    match get-state(c.state).find-stream(sid)
      Just(x) -> !x.s-has-headers && x.s-reset < 0
      Nothing -> False

fun response-status( hs : h2-headers ) : exn int
  match hs.lookup(fn(n) n == ":status").map(fn(t) parse-int(t))
    Just(Just(n)) -> n
    _ -> throw("http2: response without a valid :status")

// Send a request and give `action` the response status, headers, and body as
// a stream, read as `action` consumes it (the stream's flow control window is
// given back as it is read, so a slow reader slows the server down). The
// request body is `body`, or the parts of `upload`, sent while the response
// is read. The body stream can only be used during `action`; when `action`
// returns before the end of the body, the stream is reset. Returns `Nothing`
// if the server refused the request without processing it.
pub fun h2-stream-request( c : h2conn, method : string, scheme : string, authority : string, path : string,
                           headers : list<(string, string)>, body : bytes, upload : maybe<seq<<async,exn,ndet|e>,bytes>>,
                           action : (int, h2-headers, seq<<async,exn,ndet|e>,bytes>) -> <async,exn,ndet,div|e> a ) : <async,exn,ndet,div|e> maybe<a>
  val ch = channel()
  val hs = [(":method", method), (":scheme", scheme), (":authority", authority), (":path", path)] ++ headers.h2-filter-headers
  val end-stream = body.is-empty && upload.is-nothing
  val (sid, frames, alone) = c.open-stream(ch, hpack-encode(hs), end-stream, True, 0)
  with finally { c.close-stream(sid) }
  fun send-parts( parts : seq<_,bytes> )
    if c.answered-early(sid) then ()
    else match parts.uncons
      Just((part, rest)) ->
        if !part.is-empty then c.send-body(sid, ch, part, False)
        send-parts(rest)
      Nothing -> c.send(frame-bytes(frame-data, flag-end-stream, sid, bytes/empty))
  fun send-all()
    match upload
      Just(up) -> send-parts(up)
      Nothing -> if !body.is-empty then c.send-body(sid, ch, body, True)
  fun receive()
    match c.await-headers(sid, ch)
      Just((status, rhs)) -> Just(action(status, rhs, c.stream-body(sid, ch)))
      Nothing -> Nothing
  val sent = catch(fn(_) False, { c.send(frames); True })
  if !sent then
    c.fail("http2: the connection was closed")
    Nothing
  else
    // the response is read while the body is sent (see `h2-request`)
    val res = mask<exn>{ catch(fn(err) Error(err), { if end-stream then Ok(receive()) else Ok(interleaved(send-all, receive).snd) }) }
    match res
      Ok(r) -> r
      Error(err) ->
        if c.unprocessed(sid, alone) then
          c.fail("http2: the connection was closed: " ++ err.message)
          Nothing
        else throw-exn(err)

// Wait for the response headers on a stream: `Nothing` if the server refused the stream.
fun await-headers( c : h2conn, sid : int, ch : channel<()> ) : <async,exn,ndet> maybe<(int, h2-headers)>
  val (s, err) = async-ioc
    val st = get-state(c.state)
    (st.find-stream(sid), st.c-error)
  match s
    Just(x) | x.s-reset == err-refused-stream -> Nothing
    Just(x) | x.s-has-headers ->
      Just((x.s-headers.response-status, x.s-headers.filter(fn((n, _)) !n.starts-with(":").is-just)))
    Just(x) | x.s-reset >= 0 -> throw("http2: stream reset by the server (error " ++ x.s-reset.show ++ ")")
    Just(_) | err.is-empty ->
      c.wait-for(ch)
      c.await-headers(sid, pretend-decreasing(ch))
    _ -> throw(if err.is-empty then "http2: the stream was closed" else err)

// Wait for the complete response on a stream.
fun await-response( c : h2conn, sid : int, ch : channel<()> ) : <async,exn,ndet> maybe<(int, h2-headers, bytes)>
  // wait for the complete response
  fun go( round : int ) : <async,exn,ndet> maybe<(int, h2-headers, bytes)>
    val (s, err) = async-ioc
      val st = get-state(c.state)
      (st.find-stream(sid), st.c-error)
    match s
      Just(x) | x.s-reset == err-refused-stream -> Nothing
      Just(x) | x.s-reset >= 0 && !(x.s-reset == err-no-error && x.s-has-headers && x.s-done) ->
        throw("http2: stream reset by the server (error " ++ x.s-reset.show ++ ")")
      Just(x) | x.s-has-headers && x.s-done ->
        Just((x.s-headers.response-status, x.s-headers.filter(fn((n, _)) !n.starts-with(":").is-just), x.s-body.reverse.join))
      Just(_) | err.is-empty ->
        c.wait-for(ch)
        go(pretend-decreasing(round + 1))
      _ -> throw(if err.is-empty then "http2: the stream was closed" else err)
  go(0)

// ----------------------------------------------------------------------------
// Server
// ----------------------------------------------------------------------------

// Serve HTTP/2 on a connection whose first bytes (`initial`, possibly empty)
// have already been read. `on-request` gets the request headers (with the
// pseudo headers `:method`, `:path`, `:scheme` and `:authority`) when they
// arrive, and the body as a stream of its DATA frames; it returns
// `(status, headers, body)`. If it does not read the body to the end, the
// stream is reset (with `NO_ERROR`) after the response. The connection is
// closed after `idle-timeout` without requests.
pub fun h2-serve( s : net-stream, initial : bytes, on-request : h2-handler<e>,
                  idle-timeout : duration = 5.seconds ) : <async,exn,ndet|e> ()
  val now = now-ms()
  val st : ref<global,h2state> = async-ioc { ref(new-state(initial, False, now)) }
  val q = channel()
  val c = H2conn(s, False, st, q)
  c.send(settings-frame([(3, server-max-streams), (4, our-window)]) ++ window-update(0, our-window - default-window))
  if c.read-preface(0) then
    c.serve-frames(idle-timeout, on-request)
    c.sock.close
  else c.fail-with(err-protocol, "invalid connection preface")

// Run the reader and the workers.
fun serve-frames( c : h2conn, idle-timeout : duration, on-request : h2-handler<e> ) : <async,exn,ndet|e> ()
  val workers = list(1, server-workers).map(fn(_) fn() c.server-worker(on-request, 0))
  val _ = interleaved(Cons(fn() c.server-reader(idle-timeout, 0), workers))
  ()

// Read the client connection preface.
fun read-preface( c : h2conn, round : int ) : <async,exn> bool
  val buf = async-ioc { get-state(c.state).c-buf }
  if buf.length >= 24 then
    async-ioc { set-state(c, get-state(c.state)(c-buf = buf.subbytes(24))) }
    buf.subbytes(0, 24).string == client-preface
  else
    val more = c.sock.read
    if more.is-empty then False
    else
      async-ioc
        val x = get-state(c.state)
        set-state(c, x(c-buf = x.c-buf ++ more))
      c.read-preface(pretend-decreasing(round + 1))

// Read and process frames until the connection closes (or is idle for too
// long); then stop the workers.
fun server-reader( c : h2conn, idle-timeout : duration, round : int ) : <async,ndet> ()
  val idle = async-ioc { get-state(c.state).c-streams.is-empty }
  val more = if !idle then c.read-one
             else match timeout(idle-timeout, { c.read-one })
               Just(b) -> b
               Nothing ->   // idle for too long
                 c.fail("http2: idle timeout")
                 val last = async-ioc { get-state(c.state).c-last-sid }
                 catch(fn(_) (), { c.send(goaway(last, err-no-error)) })
                 False
  if more then c.server-reader(idle-timeout, pretend-decreasing(round + 1))
  else list(1, server-workers).foreach(fn(_) c.queue.emit(Nothing))

// Handle complete requests until stopped.
fun server-worker( c : h2conn, on-request : h2-handler<e>, round : int ) : <async,exn,ndet|e> ()
  match c.queue.receive
    Just(sid) ->
      mask<exn>{ catch(fn(_) (), { c.respond(sid, on-request) }) }
      c.server-worker(on-request, pretend-decreasing(round + 1))
    Nothing -> ()

fun respond( c : h2conn, sid : int, on-request : h2-handler<e> ) : <async,exn,ndet|e> ()
  val s = async-ioc { get-state(c.state).find-stream(sid) }
  match s
    Nothing -> ()
    Just(req) ->
      with finally
        val unfinished = async-ioc
          val st = get-state(c.state)
          val x = st.find-stream(sid)
          set-state(c, st(c-streams = st.c-streams.filter(fn(y) y.s-sid != sid)))
          match x
            Just(y) -> !y.s-done && y.s-reset < 0 && !st.c-closed
            Nothing -> False
        // the client is still sending a body that was not read: stop it (RFC 9113 section 8.1)
        if unfinished then catch(fn(_) (), { c.send(rst-stream(sid, err-no-error)) })
      if req.s-reset >= 0 then return ()
      val body-in = c.stream-body(sid, req.s-ch)
      val (status, hs, body) = mask<exn>{ catch(fn(e) (500, [("content-type", "text/plain; charset=utf-8")], H2-bytes(("internal server error: " ++ e.message).bytes)),
                                                { on-request(req.s-headers, body-in) }) }
      val method = req.s-headers.lookup(fn(n) n == ":method").default("")
      val hs' = Cons((":status", status.show), hs.h2-filter-headers)
      match body
        H2-bytes(b) -> c.send-message(sid, req.s-ch, hs', if method == "HEAD" then bytes/empty else b)
        H2-writer(_) | method == "HEAD" -> c.send-message(sid, req.s-ch, hs', bytes/empty)
        H2-writer(w) ->
          val max-frame = async-ioc { get-state(c.state).c-max-frame }
          c.send(header-frames(sid, hpack-encode(hs'), False, max-frame))
          val ok = catch(fn(_) False, {
            pretend-no-div { w(fn(part) if !part.is-empty then pretend-no-ndet { c.send-body(sid, req.s-ch, part, False) }) }
            True })
          if ok then c.send(frame-bytes(frame-data, flag-end-stream, sid, bytes/empty))
          else catch(fn(_) (), { c.send(rst-stream(sid, err-internal)) })

// The body of a request (on a server) or a response (on a client streaming
// it) as a stream: the data received on stream `sid` so far, and then the
// data as it arrives. The stream's flow control window is given back as the
// data is read.
fun stream-body( c : h2conn, sid : int, ch : channel<()> ) : seq<<async,exn,ndet|e>,bytes>
  seq/suspend fn()
    val (found, data, done, reset) = async-ioc
      val st = get-state(c.state)
      match st.find-stream(sid)
        Just(x) ->
          set-state(c, st.update-stream(sid, fn(y) y(s-body = [])))
          (True, x.s-body.reverse.join, x.s-done, x.s-reset)
        Nothing -> (False, bytes/empty, False, -1)
    if !found then throw("http2: the stream was closed")
    elif reset >= 0 && !(reset == err-no-error && done) then throw("http2: stream reset by the peer (error " ++ reset.show ++ ")")
    elif !data.is-empty then
      if !done then c.send(window-update(sid, data.length))
      Yield(data, c.stream-body(pretend-decreasing(sid), ch))
    elif done then Done
    else
      val err = async-ioc { get-state(c.state).c-error }
      if !err.is-empty then throw(err)
      c.wait-for(ch)
      c.stream-body(pretend-decreasing(sid), ch).next
