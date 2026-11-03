/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// Primitive in-memory TLS client and server engine (mbedtls) for the C backend; see `std/async/os/tls`.
module uv/tls

// static linking order matters: tls, then x509, then crypto
extern import
  c[host=libc] { library="mbedtls" }

extern import
  c[host=libc] { library="mbedx509" }

extern import
  c[host=libc] { library="mbedcrypto" }

extern import
  c  file "tls.c"
  js file "tls.js"

pub extern tls-new( host : string, verify : bool, ca : string, cert : string, key : string, alpn : string ) : ioc any
  c  "kk_tls_new"
  js "kk_tls_new"

pub extern tls-error( t : any ) : ioc string
  c  "kk_tls_error"
  js "kk_tls_error"

pub extern tls-handshake( t : any ) : ioc int
  c  "kk_tls_handshake"
  js "kk_tls_handshake"

pub extern tls-take-output( t : any ) : ioc bytes
  c  "kk_tls_take_output"
  js "kk_tls_take_output"

pub extern tls-feed( t : any, data : bytes, eof : bool ) : ioc ()
  c  "kk_tls_feed"
  js "kk_tls_feed"

pub extern tls-read( t : any ) : ioc (int, bytes)
  c  "kk_tls_read"
  js "kk_tls_read"

pub extern tls-write( t : any, data : bytes ) : ioc int
  c  "kk_tls_write"
  js "kk_tls_write"

pub extern tls-close-notify( t : any ) : ioc ()
  c  "kk_tls_close_notify"
  js "kk_tls_close_notify"

// A server configuration (C: shared mbedtls configuration; Node.js: a secure context).
pub extern tls-server-config-new( cert : string, key : string, client-ca : string, client-cert-required : bool, alpn : string ) : ioc any
  c  "kk_tls_server_config_new"
  js "kk_tls_server_config_new"

pub extern tls-server-config-error( conf : any ) : ioc string
  c  "kk_tls_server_config_error"
  js "kk_tls_server_config_error"

pub extern tls-new-server( conf : any ) : ioc any
  c  "kk_tls_new_server"
  js "kk_tls_new_server"

// The negotiated ALPN protocol ("" if none).
pub extern tls-alpn( t : any ) : ioc string
  c  "kk_tls_alpn"
  js "kk_tls_alpn"

// The subject of the verified peer certificate ("" if none).
pub extern tls-peer-subject( t : any ) : ioc string
  c  "kk_tls_peer_subject"
  js "kk_tls_peer_subject"
