/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// Primitive TCP, UDP and child process bindings (libuv on C, `net` and `child_process`
// on Node.js); see `std/async/os/net`, `std/async/os/udp` and `std/async/os/process`
// for the public API.
module uv/net

import std/num/int32
import uv/evloop

extern import
  c  file "net.c"
  js file "net.js"

pub extern net-resolve-setup( evloop : any, host : string, cb : error<vector<string>> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_net_resolve_setup"
  js "kk_net_resolve_setup"

pub extern net-connect-setup( evloop : any, ip : string, port : int32, cb : error<any> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_net_connect_setup"
  js "kk_net_connect_setup"

pub extern net-read-setup( evloop : any, sock : any, cb : error<bytes> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_net_read_setup"
  js "kk_net_read_setup"

pub extern net-write-setup( evloop : any, sock : any, data : bytes, cb : error<()> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_net_write_setup"
  js "kk_net_write_setup"

pub extern net-shutdown-setup( evloop : any, sock : any, cb : error<()> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_net_shutdown_setup"
  js "kk_net_shutdown_setup"

pub extern net-close( sock : any ) : ioc ()
  c  "kk_net_close"
  js "kk_net_close"

pub extern net-listen-setup( evloop : any, ip : string, port : int32, backlog : int32, cb : error<any> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_net_listen_setup"
  js "kk_net_listen_setup"

pub extern net-try-accept( server : any ) : ioc maybe<any>
  c  "kk_net_try_accept"
  js "kk_net_try_accept"

pub extern net-wait-connection-setup( evloop : any, server : any, cb : error<()> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_net_wait_connection_setup"
  js "kk_net_wait_connection_setup"

pub extern net-address( sock : any, peer : bool ) : ioc (string, int)
  c  "kk_net_address"
  js "kk_net_address"

pub extern net-set-nodelay( sock : any, enable : bool ) : ioc ()
  c  "kk_net_set_nodelay"
  js "kk_net_set_nodelay"

// Connect with TLS natively (Node.js only); returns a socket usable with the other primitives.
pub extern net-tls-connect-setup( evloop : any, host : string, port : int32, servername : string, verify : bool, ca : string, crl : string, cert : string, key : string, alpn : string, cb : error<any> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_net_tls_connect_setup"
  js "kk_net_tls_connect_setup"

// Start TLS as the server on an accepted socket natively (Node.js only); `conf` is from `uv/tls/tls-server-config-new`.
pub extern net-tls-accept-setup( evloop : any, sock : any, conf : any, cb : error<any> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_net_tls_accept_setup"
  js "kk_net_tls_accept_setup"

// The negotiated ALPN protocol of a native TLS socket ("" if none).
pub extern net-tls-alpn( sock : any ) : ioc string
  c  "kk_net_tls_alpn"
  js "kk_net_tls_alpn"

// The subject of the verified peer certificate of a native TLS socket ("" if none).
pub extern net-tls-peer-subject( sock : any ) : ioc string
  c  "kk_net_tls_peer_subject"
  js "kk_net_tls_peer_subject"

// The peer's certificate chain of a native TLS socket (leaf first), as DER certificates one after another.
pub extern net-tls-peer-chain( sock : any ) : ioc bytes
  c  "kk_net_tls_peer_chain"
  js "kk_net_tls_peer_chain"

// Is TLS provided natively by the host (Node.js)? Otherwise use the `uv/tls` engine.
pub extern net-has-native-tls() : bool
  c  inline "false"
  js inline "true"

// Start a child process; `mode-*` is 0 (pipe), 1 (inherit) or 2 (ignore).
pub extern proc-spawn-setup( evloop : any, cmd : string, args : vector<string>, cwd : string, env : vector<string>,
                             mode-in : int32, mode-out : int32, mode-err : int32, cb : error<any> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_proc_spawn_setup"
  js "kk_proc_spawn_setup"

// Take the stdin (0), stdout (1) or stderr (2) pipe of a process, usable with the `net-` primitives.
pub extern proc-take-stdio( proc : any, i : int32 ) : ioc maybe<any>
  c  "kk_proc_take_stdio"
  js "kk_proc_take_stdio"

pub extern proc-wait-setup( evloop : any, proc : any, cb : error<int> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_proc_wait_setup"
  js "kk_proc_wait_setup"

pub extern proc-kill( proc : any, signal : int32 ) : ioc ()
  c  "kk_proc_kill"
  js "kk_proc_kill"

pub extern proc-pid( proc : any ) : ioc int32
  c  "kk_proc_pid"
  js "kk_proc_pid"

pub extern proc-close( proc : any ) : ioc ()
  c  "kk_proc_close"
  js "kk_proc_close"

pub extern udp-bind-setup( evloop : any, ip : string, port : int32, cb : error<any> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_udp_bind_setup"
  js "kk_udp_bind_setup"

pub extern udp-recv-setup( evloop : any, sock : any, cb : error<(bytes, string, int)> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_udp_recv_setup"
  js "kk_udp_recv_setup"

pub extern udp-send-setup( evloop : any, sock : any, data : bytes, ip : string, port : int32, cb : error<()> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_udp_send_setup"
  js "kk_udp_send_setup"

pub extern udp-close( sock : any ) : ioc ()
  c  "kk_udp_close"
  js "kk_udp_close"

pub extern udp-address( sock : any ) : ioc (string, int)
  c  "kk_udp_address"
  js "kk_udp_address"

pub extern udp-set-broadcast( sock : any, enable : bool ) : ioc error<()>
  c  "kk_udp_set_broadcast"
  js "kk_udp_set_broadcast"

pub extern udp-connect( sock : any, ip : string, port : int32 ) : ioc error<()>
  c  "kk_udp_connect"
  js "kk_udp_connect"

pub extern udp-connect-setup( evloop : any, sock : any, ip : string, port : int32, cb : error<()> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_udp_connect_setup"
  js "kk_udp_connect_setup"

pub extern udp-peer-address( sock : any ) : ioc (string, int)
  c  "kk_udp_peer_address"
  js "kk_udp_peer_address"

pub extern udp-set-membership( sock : any, group : string, iface : string, join : bool ) : ioc error<()>
  c  "kk_udp_set_membership"
  js "kk_udp_set_membership"

pub extern udp-set-multicast-ttl( sock : any, ttl : int32 ) : ioc error<()>
  c  "kk_udp_set_multicast_ttl"
  js "kk_udp_set_multicast_ttl"

pub extern udp-set-multicast-loop( sock : any, enable : bool ) : ioc error<()>
  c  "kk_udp_set_multicast_loop"
  js "kk_udp_set_multicast_loop"

pub extern udp-set-multicast-interface( sock : any, iface : string ) : ioc error<()>
  c  "kk_udp_set_multicast_interface"
  js "kk_udp_set_multicast_interface"
