/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* TLS client connections.

   ```
   with s = tls-connect("example.com", 443)
   s.write-text("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
   println(s.read-all-text)
   ```

   On the C backend this uses mbedtls (with the system CA certificates, or the
   bundle in `SSL_CERT_FILE`); on Node.js it uses the built-in `tls` module.

   A `:net-stream` is either a plain TCP socket or a TLS connection, so code like
   the HTTP client can work with both.
*/
module async/os/tls

import std/core/undiv
import std/num/int32
import async/async
import async/internal
import async/os/net
import async/api/net
  [host=libc|jsnode] async/api/uv/net
import async/api/tls
  [host=libc|jsnode] async/api/uv/tls

// A byte stream over a TCP socket, possibly encrypted with TLS.
abstract struct net-stream
  sock : tcp-socket
  engine : maybe<any>   // the TLS engine (C backend); `Nothing` for plain sockets or native TLS
  secure : bool

// A plain (unencrypted) stream over a TCP socket.
pub fun plain-stream( s : tcp-socket ) : net-stream
  Net-stream(s, Nothing, False)

// Is the stream encrypted?
pub fun is-secure( s : net-stream ) : bool
  s.secure

// Connect to `host` on `port` with TLS. With `verify=False` the server
// certificate is not checked (only use this for testing).
pub fun tls-connect( host : string, port : int = 443, verify : bool = True ) : <async,exn,net> net-stream
  with try-exn-prepend("tls connect to " ++ host ++ ":" ++ port.show)
  if net-has-native-tls() then
    val h = await("tls-connect", fn(evloop, resume) net-tls-connect-setup(evloop, host, port.int32, verify, resume))
    Net-stream(@unsafe-tcp-socket(h), Nothing, True)
  else
    val sock = tcp-connect(host, port)
    val t = async-ioc { tls-new(host, verify) }
    val err = async-ioc { tls-error(t) }
    if !err.is-empty then
      sock.close
      throw(err)
    match catch-error({ handshake(sock, t) })
      Error(exn) ->
        sock.close
        throw-exn(exn)
      Ok -> Net-stream(sock, Just(t), True)

// Connect, run `action` with the stream, and close it afterwards.
pub fun scoped/tls-connect( host : string, port : int, action : net-stream -> <async,exn,net|e> a, verify : bool = True ) : <async,exn,net|e> a
  val s = tls-connect(host, port, verify)
  with finally { s.close }
  action(s)

fun catch-error( action : () -> <async,exn> a ) : async error<a>
  catch(fn(exn) Error(exn), { Ok(action()) })

fun flush( sock : tcp-socket, t : any ) : <async,exn> ()
  val out = async-ioc { tls-take-output(t) }
  if !out.is-empty then sock.write-all(out)

fun handshake( sock : tcp-socket, t : any ) : <async,exn> ()
  val st = async-ioc { tls-handshake(t) }
  flush(sock, t)
  if st == 0 then ()
  elif st == 1 then
    val data = sock.read
    async-ioc { tls-feed(t, data, data.is-empty) }
    handshake(sock, pretend-decreasing(t))
  else throw(async-ioc { tls-error(t) })

// Read the next chunk of data; empty bytes at the end of the stream.
pub fun net-stream/read( s : net-stream ) : <async,exn> bytes
  match s.engine
    Nothing -> s.sock.read
    Just(t) -> tls-read-loop(s.sock, t)

fun tls-read-loop( sock : tcp-socket, t : any ) : <async,exn> bytes
  val (st, data) = async-ioc { tls-read(t) }
  flush(sock, t)
  if st == 0 then data
  elif st == 2 then bytes/empty
  elif st == 1 then
    val more = sock.read
    async-ioc { tls-feed(t, more, more.is-empty) }
    tls-read-loop(sock, pretend-decreasing(t))
  else throw(async-ioc { tls-error(t) })

// Read until the end of the stream.
pub fun net-stream/read-all( s : net-stream ) : <async,exn> bytes
  fun go( acc : list<bytes> ) : <async,exn> list<bytes>
    val b = s.read
    if b.is-empty then acc.reverse else go(pretend-decreasing(Cons(b, acc)))
  go([]).join

// Read until the end of the stream, as UTF-8 text.
pub fun net-stream/read-all-text( s : net-stream ) : <async,exn> string
  s.read-all.string

// Write all the bytes.
pub fun net-stream/write-all( s : net-stream, data : bytes ) : <async,exn> ()
  match s.engine
    Nothing -> s.sock.write-all(data)
    Just(t) ->
      val st = async-ioc { tls-write(t, data) }
      flush(s.sock, t)
      if st != 0 then throw(async-ioc { tls-error(t) })

// Write a string (as UTF-8).
pub fun net-stream/write-text( s : net-stream, text : string ) : <async,exn> ()
  s.write-all(text.bytes)

// Close the stream (sending a TLS close notification first).
pub fun net-stream/close( s : net-stream ) : async ()
  match s.engine
    Just(t) ->
      async-ioc { tls-close-notify(t) }
      catch(fn(_) (), { flush(s.sock, t) })
    Nothing -> ()
  s.sock.close
