/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* TLS client and server connections.

   ```
   with s = tls-connect("example.com", 443)
   s.write-text("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
   println(s.read-all-text)
   ```

   A server accepts TCP connections as usual and then starts TLS on each:

   ```
   val config = tls-server-config(read-text-file("cert.pem".path), read-text-file("key.pem".path))
   val server = tcp-listen("0.0.0.0", 8443)
   server.serve fn(conn)
     val s = conn.tls-accept(config)
     s.write-text("hello over TLS\n")
     s.close-notify
   ```

   Servers can ask clients for a certificate (`client-ca` in
   `tls-server-config`), and both sides can negotiate an application protocol
   with ALPN (used for HTTP/2).

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

// Connect to `host` on `port` with TLS. The server certificate is checked
// against the system CA certificates, or only against `ca` (PEM
// certificates) if it is given. With `verify=False` the server certificate is
// not checked at all (only use this for testing).
//
// - `cert`, `key`: a client certificate (PEM, possibly followed by intermediate
//   certificates) and its private key, for servers that ask for one.
// - `alpn`: application protocols to offer (for example `["h2", "http/1.1"]`);
//   see `alpn-protocol` for the one the server chose.
pub fun tls-connect( host : string, port : int = 443, verify : bool = True, ca : string = "",
                     cert : string = "", key : string = "", alpn : list<string> = [] ) : <async,exn,net> net-stream
  with try-exn-prepend("tls connect to " ++ host ++ ":" ++ port.show)
  val alpns = alpn.join(",")
  if net-has-native-tls() then
    val h = await("tls-connect", fn(evloop, resume) net-tls-connect-setup(evloop, host, port.int32, verify, ca, cert, key, alpns, resume))
    Net-stream(@unsafe-tcp-socket(h), Nothing, True)
  else
    val sock = tcp-connect(host, port)
    val t = async-ioc { tls-new(host, verify, ca, cert, key, alpns) }
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
pub fun scoped/tls-connect( host : string, port : int, action : net-stream -> <async,exn,net|e> a, verify : bool = True, ca : string = "",
                            cert : string = "", key : string = "", alpn : list<string> = [] ) : <async,exn,net|e> a
  val s = tls-connect(host, port, verify, ca, cert, key, alpn)
  with finally { s.close }
  action(s)

// A TLS server configuration: a certificate chain and its private key.
abstract struct tls-config( hnd : any )

// Create a server configuration from a PEM certificate chain (the server
// certificate first, followed by any intermediate certificates) and a PEM
// private key. Raises an exception if they are invalid or do not match.
//
// - `client-ca`: if given (PEM certificates), clients are asked for a
//   certificate signed by it; see `peer-certificate`. A client without one is
//   rejected if `client-cert-required` (and accepted otherwise), and a client
//   with an invalid one is always rejected.
// - `alpn`: application protocols the server supports, in order of
//   preference (for example `["h2", "http/1.1"]`).
pub fun tls-server-config( cert-chain : string, private-key : string, client-ca : string = "", client-cert-required : bool = True,
                           alpn : list<string> = [] ) : <async,exn> tls-config
  val c = async-ioc { tls-server-config-new(cert-chain, private-key, client-ca, client-cert-required, alpn.join(",")) }
  val err = async-ioc { tls-server-config-error(c) }
  if !err.is-empty then throw("tls server config: " ++ err)
  Tls-config(c)

// Start TLS as the server on an accepted connection: performs the handshake
// and returns the encrypted stream. The socket stays owned by the caller (and
// must still be closed by it), also when the handshake fails.
pub fun tls-accept( sock : tcp-socket, config : tls-config ) : <async,exn> net-stream
  with try-exn-prepend("tls accept")
  if net-has-native-tls() then
    val h = await("tls-accept", fn(evloop, resume) net-tls-accept-setup(evloop, sock.@unsafe-hnd, config.hnd, resume))
    Net-stream(@unsafe-tcp-socket(h), Nothing, True)
  else
    val t = async-ioc { tls-new-server(config.hnd) }
    val err = async-ioc { tls-error(t) }
    if !err.is-empty then throw(err)
    handshake(sock, t)
    Net-stream(sock, Just(t), True)

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

// The application protocol negotiated with ALPN (for example `"h2"`), or
// `Nothing` if none was (or the stream is not encrypted).
pub fun alpn-protocol( s : net-stream ) : async maybe<string>
  val p = match s.engine
    Just(t) -> async-ioc { tls-alpn(t) }
    Nothing -> if s.secure then async-ioc { net-tls-alpn(s.sock.@unsafe-hnd) } else ""
  if p.is-empty then Nothing else Just(p)

// The subject of the peer's verified certificate (for example
// `"CN=example.com"`): on a client the server's certificate (if verified), and
// on a server the client certificate (if one was presented).
pub fun peer-certificate( s : net-stream ) : async maybe<string>
  val subj = match s.engine
    Just(t) -> async-ioc { tls-peer-subject(t) }
    Nothing -> if s.secure then async-ioc { net-tls-peer-subject(s.sock.@unsafe-hnd) } else ""
  if subj.is-empty then Nothing else Just(subj)

// The remote `(ip, port)` of the stream.
pub fun net-stream/peer-address( s : net-stream ) : async (string, int)
  s.sock.peer-address

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

// Send a TLS close notification, telling the peer that no more data follows,
// without closing the underlying socket. Does nothing on a plain stream.
pub fun close-notify( s : net-stream ) : async ()
  match s.engine
    Just(t) ->
      async-ioc { tls-close-notify(t) }
      catch(fn(_) (), { flush(s.sock, t) })
    Nothing ->
      if s.secure then catch(fn(_) (), { s.sock.shutdown-write })

// Close the stream (sending a TLS close notification first).
pub fun net-stream/close( s : net-stream ) : async ()
  match s.engine
    Just(t) ->
      async-ioc { tls-close-notify(t) }
      catch(fn(_) (), { flush(s.sock, t) })
    Nothing -> ()
  s.sock.close
