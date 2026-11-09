/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// On Node.js, TLS is provided natively (see `kk_net_tls_connect_setup` and
// `kk_net_tls_accept_setup` in net.js); the in-memory engine is not used.
const tls = ($std_core_console._host === "node" ? await import('tls') : null);
const crypto = ($std_core_console._host === "node" ? await import('crypto') : null);

// Node ignores CA text without certificates; check that each one parses.
function kk_tls_check_certs(pem, what) {
  const certs = pem.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g);
  if (!certs) throw new Error("invalid " + what + ": no certificates found");
  for (const c of certs) new crypto.X509Certificate(c);
}
function kk_tls_unsupported() { throw new Error("the TLS engine is not used on this host"); }
export function kk_tls_new(host, verify, ca, cert, key, alpn) { return null; }
export function kk_tls_error(t) { return "the TLS engine is not available on this host"; }
export function kk_tls_handshake(t) { return -1; }
export function kk_tls_take_output(t) { return new Uint8Array(0); }
export function kk_tls_feed(t, data, eof) { return $std_core_types.Unit; }
export function kk_tls_read(t) { return $std_core_types.Tuple2(-1, new Uint8Array(0)); }
export function kk_tls_write(t, data) { return -1; }
export function kk_tls_close_notify(t) { return $std_core_types.Unit; }
export function kk_tls_new_server(conf) { return null; }

// A server configuration is a secure context (or an error message)
// Does a server name match a host pattern (a name, or `*.domain` for one label)?
function kk_tls_name_matches(pat, name) {
  pat = pat.toLowerCase(); name = name.toLowerCase();
  if (pat.startsWith("*.")) {
    const dot = name.indexOf(".");
    return (dot > 0 && name.slice(dot) === pat.slice(1));
  }
  return pat === name;
}

export function kk_tls_server_config_new(cert, key, client_ca, client_cert_required, alpn, sni) {
  if (!tls) return { context: null, error: "TLS is not supported on this host" };
  try {
    const opts = { cert: cert, key: key };
    const fields = (sni.length > 0 ? sni.split("\x01") : []);
    const named = [];
    for (let i = 0; i + 2 < fields.length; i += 3) {
      const nopts = { cert: fields[i+1], key: fields[i+2] };
      if (client_ca.length > 0) nopts.ca = client_ca;
      let context;
      try { context = tls.createSecureContext(nopts); }
      catch (e) { throw new Error("invalid SNI certificate or key for " + fields[i] + ": " + (e instanceof Error ? e.message : String(e))); }
      named.push({ pattern: fields[i], context: context });
    }
    if (client_ca.length > 0) {
      kk_tls_check_certs(client_ca, "client CA certificate");
      opts.ca = client_ca;
    }
    return { context: tls.createSecureContext(opts), error: "",
             requestCert: client_ca.length > 0, requireCert: client_ca.length > 0 && client_cert_required,
             alpn: (alpn.length > 0 ? alpn.split(",") : null),
             sni: (named.length === 0 ? null : (servername) => {
               const m = named.find((n) => kk_tls_name_matches(n.pattern, servername || ""));
               return (m ? m.context : null);
             }) };
  }
  catch (e) {
    return { context: null, error: (e instanceof Error ? e.message : String(e)) };
  }
}
export function kk_tls_server_config_error(conf) { return conf.error; }
export function kk_tls_alpn(t) { return ""; }
export function kk_tls_peer_subject(t) { return ""; }

