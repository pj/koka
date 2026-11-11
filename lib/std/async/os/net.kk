/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Asynchronous TCP networking.

   Supported on the C backend (using libuv) and on Node.js.

   ```
   import std/async
   import std/async/os/net

   fun main()
     // a tiny echo server, and a client talking to it
     val server = tcp-listen("127.0.0.1", 0)
     val port = server.local-port
     interleaved({
       with conn = server.accept
       conn.write-all(conn.read)
     },{
       with c = tcp-connect("localhost", port)
       c.write-text("hello")
       println(c.read.string)
     })
     server.close
   ```

   Sockets and servers must be closed explicitly (or used with the scoped
   `with conn = ...` forms which close them automatically).
*/
module async/os/net

import std/core/undiv
pub import std/io/stream
import std/num/int32
import async/async
import async/internal
import async/interleave
import async/api/net
  [host=libc|jsnode] async/api/uv/net

// A connected TCP socket.
abstract struct tcp-socket( hnd : any, closed : ref<global,bool> )

// A listening TCP server.
abstract struct tcp-server( hnd : any, closed : ref<global,bool> )

// Internal: wrap a primitive socket handle (used by `std/async/os/tls` and `std/async/os/process`).
pub fun @unsafe-tcp-socket( h : any ) : async tcp-socket
  async-ioc { Tcp-socket(h, ref(False)) }

// Mark a socket as closed; `True` if it already was. Closing a handle twice
// is not safe (it may be freed after the first close), so `close` is
// idempotent at this level.
fun mark-closed( r : ref<global,bool> ) : async bool
  async-ioc
    val was = get-flag(r)
    r := True
    was

// (a signature is needed here: inferring the effect of reading the ref fails)
fun get-flag( r : ref<global,bool> ) : <read<global>,div> bool
  !r

// Internal: the primitive socket handle (used by `std/async/os/tls`).
pub fun @unsafe-hnd( s : tcp-socket ) : any
  s.hnd

// Resolve a host name to a list of IP addresses (IPv4 and IPv6).
pub fun resolve-host( host : string ) : <async,exn,net> list<string>
  with try-exn-prepend("resolve " ++ host.show)
  await("net-resolve", fn(evloop, resume) net-resolve-setup(evloop, host, resume)).list

fun is-ip-address( s : string ) : bool
  s.list.all(fn(c) c.is-digit || c == '.') || s.list.any(fn(c) c == ':')

// Connect to `host` (a host name or IP address) on `port`. Tries each
// resolved address in turn until one succeeds.
pub fun tcp-connect( host : string, port : int ) : <async,exn,net> tcp-socket
  with try-exn-prepend("connect to " ++ host ++ ":" ++ port.show)
  val ips = if host.is-ip-address then [host] else resolve-host(host)
  connect-first(ips, port, Nothing)

fun connect-first( ips : list<string>, port : int, last-err : maybe<exception> ) : <async,exn,net> tcp-socket
  match ips
    Nil -> match last-err
      Just(exn) -> throw-exn(exn)
      Nothing -> throw("no addresses found")
    Cons(ip, rest) ->
      val res = setup/await-error1("net-connect", fn(evloop, resume) net-connect-setup(evloop, ip, port.int32, resume))
      match res
        Ok(h) -> @unsafe-tcp-socket(h)
        Error(exn) -> connect-first(rest, port, Just(exn))

// Connect, run `action` with the socket, and close the socket afterwards.
pub fun scoped/tcp-connect( host : string, port : int, action : tcp-socket -> <async,exn,net|e> a ) : <async,exn,net|e> a
  val s = tcp-connect(host, port)
  with finally { s.close }
  action(s)

// Read the next chunk of available data. Returns empty bytes at the end of the stream.
pub fun read( s : tcp-socket ) : <async,exn> bytes
  await("net-read", fn(evloop, resume) net-read-setup(evloop, s.hnd, resume))

// The data received on the socket as a stream, until the other end closes
// its side. The stream is consumed as it is read (see `std/io/stream`).
pub fun tcp-socket/stream( s : tcp-socket ) : byte-stream<<async,exn|e>>
  from-reader(fn() s.read)

// Read until the other end closes the connection.
pub fun read-all( s : tcp-socket ) : <async,exn> bytes
  fun go( acc : list<bytes> ) : <async,exn> list<bytes>
    val b = s.read
    if b.is-empty then acc.reverse else go(pretend-decreasing(Cons(b, acc)))
  go([]).join

// Read until the other end closes the connection, as UTF-8 text.
pub fun read-all-text( s : tcp-socket ) : <async,exn> string
  s.read-all.string

// Write all the bytes to the socket.
pub fun write-all( s : tcp-socket, data : bytes ) : <async,exn> ()
  if data.is-empty then () else
    await("net-write", fn(evloop, resume) net-write-setup(evloop, s.hnd, data, resume))

// Queue bytes to be written without waiting until they are written. The write
// is ordered with the other writes on the socket; an error shows up on a later
// read or write. (A reader can answer the peer without blocking on a full send
// buffer, which could deadlock two peers that both wait to write.)
pub fun write-queued( s : tcp-socket, data : bytes ) : <async,exn> ()
  if data.is-empty then () else
    do-sync(fn(evloop) queue-write(evloop, s, data), "net-write-queued")

fun queue-write( evloop : event-loop, s : tcp-socket, data : bytes ) : ioc error<()>
  match net-write-setup(evloop, s.hnd, data, fn(_) ())
    Ok(_)    -> Ok(())
    Error(e) -> Error(e)

// Write a string (as UTF-8) to the socket.
pub fun write-text( s : tcp-socket, text : string ) : <async,exn> ()
  s.write-all(text.bytes)

// Signal the end of our data to the other end (a half close): no more writes
// are possible, but reading continues to work.
pub fun shutdown-write( s : tcp-socket ) : <async,exn> ()
  await("net-shutdown", fn(evloop, resume) net-shutdown-setup(evloop, s.hnd, resume))

// Close the socket (closing it again does nothing).
pub fun tcp-socket/close( s : tcp-socket ) : async ()
  if !mark-closed(s.closed) then async-ioc { net-close(s.hnd) }

// Enable or disable Nagle's algorithm (`enable=True` sends small writes immediately).
pub fun set-nodelay( s : tcp-socket, enable : bool = True ) : async ()
  async-ioc { net-set-nodelay(s.hnd, enable) }

// The local `(ip, port)` of the socket.
pub fun tcp-socket/local-address( s : tcp-socket ) : async (string, int)
  async-ioc { net-address(s.hnd, False) }

// The remote `(ip, port)` of the socket.
pub fun peer-address( s : tcp-socket ) : async (string, int)
  async-ioc { net-address(s.hnd, True) }

// Listen for TCP connections on `ip` (for example `"0.0.0.0"` for all IPv4
// interfaces, or `"::"` for IPv6) and `port`; use port `0` to pick a free port.
pub fun tcp-listen( ip : string, port : int, backlog : int = 128 ) : <async,exn,net> tcp-server
  with try-exn-prepend("listen on " ++ ip ++ ":" ++ port.show)
  val h = await("net-listen", fn(evloop, resume) net-listen-setup(evloop, ip, port.int32, backlog.int32, resume))
  async-ioc { Tcp-server(h, ref(False)) }

// Wait for and accept the next incoming connection.
pub fun accept( srv : tcp-server ) : <async,exn> tcp-socket
  val queued = async-ioc { net-try-accept(srv.hnd) }
  match queued
    Just(h) -> @unsafe-tcp-socket(h)
    Nothing ->
      await("net-accept", fn(evloop, resume) net-wait-connection-setup(evloop, srv.hnd, resume))
      accept(pretend-decreasing(srv))

// Accept a connection, run `action` with it, and close it afterwards.
pub fun scoped/accept( srv : tcp-server, action : tcp-socket -> <async,exn|e> a ) : <async,exn|e> a
  val s = srv.accept
  with finally { s.close }
  action(s)

// The local `(ip, port)` the server listens on.
pub fun tcp-server/local-address( srv : tcp-server ) : async (string, int)
  async-ioc { net-address(srv.hnd, False) }

// The local port the server listens on (useful after listening on port `0`).
pub fun local-port( srv : tcp-server ) : async int
  srv.local-address.snd

// Stop listening and close any connections that were not yet accepted.
pub fun tcp-server/close( srv : tcp-server ) : async ()
  if !mark-closed(srv.closed) then async-ioc { net-close(srv.hnd) }

// Serve connections forever: each accepted connection is handled by `on-conn`
// in its own strand (and closed afterwards). Errors in a handler are reported
// through `on-error` and do not stop the server.
pub fun serve( srv : tcp-server, on-conn : tcp-socket -> <async,exn,ndet|e> (), on-error : exception -> <async,ndet|e> () = fn(_) () ) : <async,exn,ndet|e> ()
  val conn = srv.accept
  interleaved({
    mask<exn>
      catch(on-error)
        with finally { conn.close }
        on-conn(conn)
  }, {
    serve(pretend-decreasing(srv), on-conn, on-error)
  })
  ()
