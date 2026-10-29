/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

// TCP networking on Node.js (mirrors net.c)

const net = ($std_core_console._host === "node" ? await import('net') : null);
const dns = ($std_core_console._host === "node" ? await import('dns') : null);

function kk_net_error(e) {
  return $std_core_exn._error_from_exception(e instanceof Error ? e : new Error(String(e)));
}
function kk_net_ok(x) {
  return $std_core_types.Ok(x);
}
function kk_net_notsupp() {
  return kk_net_error(new Error("networking is not supported on this host"));
}

// A socket wrapper buffers incoming chunks; the stream is paused when no read is pending.
function kk_net_wrap(sock) {
  const w = { sock: sock, chunks: [], ended: false, error: null, readcb: null, closed: false };
  sock.pause();
  sock.on("data", (d) => { w.chunks.push(d); sock.pause(); kk_net_flush(w); });
  sock.on("end", () => { w.ended = true; kk_net_flush(w); });
  sock.on("error", (e) => { w.error = e; kk_net_flush(w); });
  sock.on("close", () => { w.ended = true; kk_net_flush(w); });
  return w;
}

function kk_net_flush(w) {
  const cb = w.readcb;
  if (!cb) return;
  if (w.chunks.length > 0) {
    w.readcb = null;
    const b = w.chunks.shift();
    cb(kk_net_ok(new Uint8Array(b.buffer, b.byteOffset, b.length)));
  }
  else if (w.error) {
    w.readcb = null;
    cb(kk_net_error(w.error));
  }
  else if (w.ended || w.closed) {
    w.readcb = null;
    cb(kk_net_ok(new Uint8Array(0)));
  }
}

export function kk_net_resolve_setup(evloop, host, cb) {
  if (!dns) return kk_net_notsupp();
  let callback = cb;
  dns.lookup(host, { all: true }, (err, addrs) => {
    if (!callback) return;
    if (err) callback(kk_net_error(err));
        else callback(kk_net_ok(addrs.map((a) => a.address)));
  });
  return kk_net_ok(() => { callback = null; return $std_core_types.Unit; });
}

export function kk_net_connect_setup(evloop, ip, port, cb) {
  if (!net) return kk_net_notsupp();
  let callback = cb;
  const sock = net.createConnection({ host: ip, port: Number(port) });
  const onerror = (e) => { if (callback) { const c = callback; callback = null; c(kk_net_error(e)); } };
  sock.once("error", onerror);
  sock.once("connect", () => {
    sock.removeListener("error", onerror);
    const w = kk_net_wrap(sock);
    if (callback) { const c = callback; callback = null; c(kk_net_ok(w)); }
    else sock.destroy();
  });
  return kk_net_ok(() => { if (callback) { callback = null; sock.destroy(); } return $std_core_types.Unit; });
}

export function kk_net_read_setup(evloop, w, cb) {
  if (w.readcb) return kk_net_error(new Error("a read is already pending"));
  w.readcb = cb;
  if (w.chunks.length > 0 || w.error || w.ended || w.closed) kk_net_flush(w);
  else w.sock.resume();
  return kk_net_ok(() => { if (w.readcb === cb) { w.readcb = null; w.sock.pause(); } return $std_core_types.Unit; });
}

export function kk_net_write_setup(evloop, w, data, cb) {
  if (w.closed) return kk_net_error(new Error("socket is closed"));
  let callback = cb;
  w.sock.write(data, (err) => {
    if (!callback) return;
    if (err) callback(kk_net_error(err)); else callback(kk_net_ok($std_core_types.Unit));
  });
  return kk_net_ok(() => { callback = null; return $std_core_types.Unit; });
}

export function kk_net_shutdown_setup(evloop, w, cb) {
  if (w.closed) return kk_net_error(new Error("socket is closed"));
  let callback = cb;
  w.sock.end(() => { if (callback) callback(kk_net_ok($std_core_types.Unit)); });
  return kk_net_ok(() => { callback = null; return $std_core_types.Unit; });
}

export function kk_net_close(w) {
  if (w.server) {
    w.closed = true;
    w.server.close();
    for (const c of w.queue) c.sock.destroy();
    w.queue = [];
    if (w.conncb) { const c = w.conncb; w.conncb = null; c(kk_net_error(new Error("server closed"))); }
  }
  else if (!w.closed) {
    w.closed = true;
    w.sock.end();
    w.sock.destroySoon ? w.sock.destroySoon() : w.sock.destroy();
    kk_net_flush(w);
  }
  return $std_core_types.Unit;
}

export function kk_net_listen_setup(evloop, ip, port, backlog, cb) {
  if (!net) return kk_net_notsupp();
  let callback = cb;
  const srv = { server: null, queue: [], conncb: null, closed: false };
  const server = net.createServer({ pauseOnConnect: true }, (sock) => {
    if (srv.closed) { sock.destroy(); return; }
    srv.queue.push(kk_net_wrap(sock));
    if (srv.conncb) { const c = srv.conncb; srv.conncb = null; c(kk_net_ok($std_core_types.Unit)); }
  });
  srv.server = server;
  server.once("error", (e) => { if (callback) { const c = callback; callback = null; c(kk_net_error(e)); } });
  server.listen({ host: ip, port: Number(port), backlog: (backlog > 0 ? backlog : 128) }, () => {
    if (callback) { const c = callback; callback = null; c(kk_net_ok(srv)); }
  });
  return kk_net_ok(() => { if (callback) { callback = null; server.close(); } return $std_core_types.Unit; });
}

export function kk_net_try_accept(srv) {
  if (srv.queue.length > 0) return $std_core_types.Just(srv.queue.shift());
  return $std_core_types.Nothing;
}

export function kk_net_wait_connection_setup(evloop, srv, cb) {
  if (srv.closed) return kk_net_error(new Error("server closed"));
  if (srv.conncb) return kk_net_error(new Error("an accept is already pending"));
  srv.conncb = cb;
  return kk_net_ok(() => { if (srv.conncb === cb) srv.conncb = null; return $std_core_types.Unit; });
}

export function kk_net_address(w, peer) {
  let ip = "", port = 0;
  if (w.server) {
    const a = w.server.address();
    if (a) { ip = a.address; port = a.port; }
  }
  else if (peer) { ip = w.sock.remoteAddress || ""; port = w.sock.remotePort || 0; }
  else { ip = w.sock.localAddress || ""; port = w.sock.localPort || 0; }
  return $std_core_types.Tuple2(ip, port);
}

export function kk_net_set_nodelay(w, enable) {
  if (w.sock) w.sock.setNoDelay(enable);
  return $std_core_types.Unit;
}
