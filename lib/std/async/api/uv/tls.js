/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// On Node.js, TLS is provided natively (see `kk_net_tls_connect_setup` in net.js);
// the in-memory engine is not used.
function kk_tls_unsupported() { throw new Error("the TLS engine is not used on this host"); }
export function kk_tls_new(host, verify) { return null; }
export function kk_tls_error(t) { return "the TLS engine is not available on this host"; }
export function kk_tls_handshake(t) { return -1; }
export function kk_tls_take_output(t) { return new Uint8Array(0); }
export function kk_tls_feed(t, data, eof) { return $std_core_types.Unit; }
export function kk_tls_read(t) { return $std_core_types.Tuple2(-1, new Uint8Array(0)); }
export function kk_tls_write(t, data) { return -1; }
export function kk_tls_close_notify(t) { return $std_core_types.Unit; }
