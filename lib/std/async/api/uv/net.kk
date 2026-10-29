/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// Primitive TCP bindings (libuv on C, `net` on Node.js); see `std/async/os/net` for the public API.
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
