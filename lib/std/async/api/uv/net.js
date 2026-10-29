/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

// TCP networking and child processes on Node.js (mirrors net.c)

const net = ($std_core_console._host === "node" ? await import('net') : null);
const dns = ($std_core_console._host === "node" ? await import('dns') : null);
const tls = ($std_core_console._host === "node" ? await import('tls') : null);
const cp  = ($std_core_console._host === "node" ? await import('child_process') : null);
const os  = ($std_core_console._host === "node" ? await import('os') : null);

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
// It also wraps the (readable or writable) stdio streams of a child process.
function kk_net_wrap(sock) {
  const w = { sock: sock, chunks: [], ended: false, error: null, readcb: null, closed: false };
  if (sock.pause) sock.pause();
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
    if (w.sock.end) w.sock.end();
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

// TLS on Node: the resulting TLS socket is wrapped like a plain socket so all
// other primitives work on it unchanged.
export function kk_net_tls_connect_setup(evloop, host, port, verify, ca, cb) {
  if (!tls) return kk_net_notsupp();
  let callback = cb;
  const opts = { host: host, port: Number(port), servername: host, rejectUnauthorized: verify };
  if (ca.length > 0) opts.ca = ca;
  const sock = tls.connect(opts);
  const onerror = (e) => { if (callback) { const c = callback; callback = null; c(kk_net_error(e)); } };
  sock.once("error", onerror);
  sock.once("secureConnect", () => {
    sock.removeListener("error", onerror);
    const w = kk_net_wrap(sock);
    if (callback) { const c = callback; callback = null; c(kk_net_ok(w)); }
    else sock.destroy();
  });
  return kk_net_ok(() => { if (callback) { callback = null; sock.destroy(); } return $std_core_types.Unit; });
}

// Start TLS as the server on an accepted connection; `conf` is a server
// configuration from `kk_tls_server_config_new` in tls.js.
export function kk_net_tls_accept_setup(evloop, w, conf, cb) {
  if (!tls) return kk_net_notsupp();
  if (w.closed) return kk_net_error(new Error("socket is closed"));
  let callback = cb;
  // the TLS socket takes over the connection; the plain wrapper must not consume data anymore
  w.sock.removeAllListeners("data");
  const sock = new tls.TLSSocket(w.sock, { isServer: true, secureContext: conf.context });
  const onerror = (e) => { if (callback) { const c = callback; callback = null; c(kk_net_error(e)); } };
  sock.once("error", onerror);
  sock.once("close", () => onerror(new Error("connection closed during the TLS handshake")));
  sock.once("secure", () => {
    sock.removeListener("error", onerror);
    const t = kk_net_wrap(sock);
    if (callback) { const c = callback; callback = null; c(kk_net_ok(t)); }
    else sock.destroy();
  });
  return kk_net_ok(() => { if (callback) { callback = null; sock.destroy(); } return $std_core_types.Unit; });
}

// ---------------------------------------------------------------------------
// Child processes
// ---------------------------------------------------------------------------

function kk_proc_signal_number(sig) {
  const n = (os && sig ? os.constants.signals[sig] : undefined);
  return (n !== undefined ? n : 15);
}

export function kk_proc_spawn_setup(evloop, cmd, args, cwd, env, mode_in, mode_out, mode_err, cb) {
  if (!cp) return kk_net_error(new Error("running processes is not supported on this host"));
  const modename = (m) => (m === 0 ? "pipe" : (m === 1 ? "inherit" : "ignore"));
  const opts = { stdio: [modename(mode_in), modename(mode_out), modename(mode_err)] };
  if (cwd.length > 0) opts.cwd = cwd;
  if (env.length > 0) {
    opts.env = {};
    for (const kv of env) {
      const i = kv.indexOf("=");
      if (i > 0) opts.env[kv.substring(0, i)] = kv.substring(i + 1);
    }
  }
  let callback = cb;
  let child;
  try {
    child = cp.spawn(cmd, args, opts);
  }
  catch (e) {
    return kk_net_error(e);
  }
  const proc = { child: child, exited: false, code: 0, waitcb: null, closed: false,
                 stdio: [child.stdin, child.stdout, child.stderr].map((s) => (s ? kk_net_wrap(s) : null)) };
  child.once("exit", (code, signal) => {
    proc.exited = true;
    proc.code = (code !== null ? code : 128 + kk_proc_signal_number(signal));
    if (proc.waitcb) { const c = proc.waitcb; proc.waitcb = null; c(kk_net_ok(proc.code)); }
  });
  child.once("error", (e) => {
    if (callback) { const c = callback; callback = null; c(kk_net_error(e)); }
  });
  child.once("spawn", () => {
    if (callback) { const c = callback; callback = null; c(kk_net_ok(proc)); }
  });
  return kk_net_ok(() => { if (callback) { callback = null; child.kill(); } return $std_core_types.Unit; });
}

export function kk_proc_take_stdio(proc, i) {
  const w = proc.stdio[i];
  if (!w) return $std_core_types.Nothing;
  proc.stdio[i] = null;
  return $std_core_types.Just(w);
}

export function kk_proc_wait_setup(evloop, proc, cb) {
  if (proc.exited) { cb(kk_net_ok(proc.code)); return kk_net_ok(() => $std_core_types.Unit); }
  if (proc.closed) return kk_net_error(new Error("process handle is closed"));
  if (proc.waitcb) return kk_net_error(new Error("a wait is already pending"));
  proc.waitcb = cb;
  return kk_net_ok(() => { if (proc.waitcb === cb) proc.waitcb = null; return $std_core_types.Unit; });
}

export function kk_proc_kill(proc, signum) {
  if (!proc.exited) {
    const name = Object.keys(os.constants.signals).find((k) => os.constants.signals[k] === signum);
    try { proc.child.kill(name || signum); } catch (e) { }
  }
  return $std_core_types.Unit;
}

export function kk_proc_pid(proc) {
  return proc.child.pid || 0;
}

export function kk_proc_close(proc) {
  if (proc.closed) return $std_core_types.Unit;
  proc.closed = true;
  if (proc.waitcb) { const c = proc.waitcb; proc.waitcb = null; c(kk_net_error(new Error("process handle is closed"))); }
  for (let i = 0; i < 3; i++) {
    if (proc.stdio[i]) { kk_net_close(proc.stdio[i]); proc.stdio[i] = null; }
  }
  return $std_core_types.Unit;
}
