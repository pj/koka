/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// Primitive TCP and child process bindings (libuv on C, `net` and `child_process`
// on Node.js); see `std/async/os/net` and `std/async/os/process` for the public API.
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
pub extern net-tls-connect-setup( evloop : any, host : string, port : int32, verify : bool, cb : error<any> -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_net_tls_connect_setup"
  js "kk_net_tls_connect_setup"

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
