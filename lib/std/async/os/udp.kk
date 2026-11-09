/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Asynchronous UDP sockets.

   Supported on the C backend (using libuv) and on Node.js.

   ```
   import std/async
   import std/async/os/udp

   fun main()
     with server = udp-bind("127.0.0.1", 0)
     with client = udp-bind("127.0.0.1", 0)
     client.send-to("ping".bytes, "127.0.0.1", server.local-port)
     val (data, ip, port) = server.receive-from
     server.send-to(data, ip, port)   // echo it back
     println(client.receive-from.fst.string)
   ```

   Datagrams may be lost, duplicated, or arrive out of order; combine
   `receive-from` with `timeout` to wait for a reply only for a while.
*/
module async/os/udp

import std/num/int32
import async/async
import async/internal
import async/os/net
import async/api/net
  [host=libc|jsnode] async/api/uv/net

// A UDP socket.
abstract struct udp-socket( hnd : any, closed : ref<global,bool> )

// Create a UDP socket bound to `ip` (for example `"0.0.0.0"` for all IPv4
// interfaces, or `"::"` for IPv6) and `port`; use port `0` to pick a free port.
pub fun udp-bind( ip : string = "0.0.0.0", port : int = 0 ) : <async,exn,net> udp-socket
  with try-exn-prepend("udp bind to " ++ ip ++ ":" ++ port.show)
  val h = await("udp-bind", fn(evloop, resume) udp-bind-setup(evloop, ip, port.int32, resume))
  async-ioc { Udp-socket(h, ref(False)) }

// Create a UDP socket, run `action` with it, and close it afterwards.
pub fun scoped/udp-bind( ip : string, port : int, action : udp-socket -> <async,exn,net|e> a ) : <async,exn,net|e> a
  val s = udp-bind(ip, port)
  with finally { s.close }
  action(s)

fun is-ip-address( s : string ) : bool
  s.list.all(fn(c) c.is-digit || c == '.') || s.list.any(fn(c) c == ':')

// Send a datagram to `host` (a host name or IP address) on `port`. A host
// name is resolved to an address of the same family (IPv4 or IPv6) as the
// socket.
pub fun send-to( s : udp-socket, data : bytes, host : string, port : int ) : <async,exn,net> ()
  val ip = if host.is-ip-address then host else
    val ipv6 = s.local-address.fst.list.any(fn(c) c == ':')
    match resolve-host(host).filter(fn(a) a.list.any(fn(c) c == ':') == ipv6)
      Cons(a, _) -> a
      Nil -> throw("udp: no " ++ (if ipv6 then "IPv6" else "IPv4") ++ " address found for " ++ host.show)
  with try-exn-prepend("udp send to " ++ host ++ ":" ++ port.show)
  await("udp-send", fn(evloop, resume) udp-send-setup(evloop, s.hnd, data, ip, port.int32, resume))

// Wait for the next datagram; returns `(data, sender-ip, sender-port)`.
pub fun receive-from( s : udp-socket ) : <async,exn> (bytes, string, int)
  await("udp-receive", fn(evloop, resume) udp-recv-setup(evloop, s.hnd, resume))

// Allow (or disallow) sending to broadcast addresses.
pub fun set-broadcast( s : udp-socket, enable : bool = True ) : <async,exn> ()
  async-ioc { udp-set-broadcast(s.hnd, enable) }.untry

// Join the multicast `group` (like `"239.255.0.1"` or `"ff02::1"`) so that
// datagrams sent to it arrive on this socket; `iface` is the address of the
// local interface to use (`""` lets the system choose).
pub fun join-multicast( s : udp-socket, group : string, iface : string = "" ) : <async,exn> ()
  async-ioc { udp-set-membership(s.hnd, group, iface, True) }.untry

// Leave a multicast group.
pub fun leave-multicast( s : udp-socket, group : string, iface : string = "" ) : <async,exn> ()
  async-ioc { udp-set-membership(s.hnd, group, iface, False) }.untry

// The number of network hops (time to live) of multicast datagrams sent (1 by default: the local network).
pub fun set-multicast-ttl( s : udp-socket, ttl : int ) : <async,exn> ()
  async-ioc { udp-set-multicast-ttl(s.hnd, ttl.int32) }.untry

// Whether multicast datagrams sent from this host also arrive at its own sockets (on by default).
pub fun set-multicast-loop( s : udp-socket, enable : bool = True ) : <async,exn> ()
  async-ioc { udp-set-multicast-loop(s.hnd, enable) }.untry

// The local interface (by its address) that multicast datagrams are sent from.
pub fun set-multicast-interface( s : udp-socket, iface : string ) : <async,exn> ()
  async-ioc { udp-set-multicast-interface(s.hnd, iface) }.untry

// The local `(ip, port)` the socket is bound to.
pub fun udp-socket/local-address( s : udp-socket ) : async (string, int)
  async-ioc { udp-address(s.hnd) }

// The local port the socket is bound to (useful after binding to port `0`).
pub fun udp-socket/local-port( s : udp-socket ) : async int
  s.local-address.snd

// Close the socket; a pending `receive-from` raises an exception.
pub fun udp-socket/close( s : udp-socket ) : async ()
  val was = async-ioc
    val r : ref<global,bool> = s.closed
    val x = get-closed(r)
    r := True
    x
  if !was then async-ioc { udp-close(s.hnd) }

// (a signature is needed here: inferring the effect of reading the ref fails)
fun get-closed( r : ref<global,bool> ) : <read<global>,div> bool
  !r
