/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
var _os_constants = null;
if ($std_core.host()=="node") {
  _os_constants = (await import("os")).constants;
}

// The signals in the order of the `signal` type in std/async/os/signal.
const _signal_names = ["SIGINT","SIGTERM","SIGHUP","SIGQUIT","SIGUSR1","SIGUSR2","SIGWINCH","SIGPIPE","SIGCHLD"];

function _signal_name( code ) {
  const name = _signal_names[Number(code)];
  if (name === undefined || _os_constants === null || _os_constants.signals[name] === undefined) return null;
  return name;
}

export function kk_signal_setup( evloop, code, cb ) {
  const name = _signal_name(code);
  if (name === null) return $std_core_exn._error_from_exception(new Error("signal not supported on this platform"));
  // a signal listener does not keep Node's event loop alive, but a waiting strand should
  const keep = setInterval(() => {}, 1 << 30);
  let done = false;
  const listener = () => {
    if (done) return;
    done = true;
    clearInterval(keep);
    cb();
  };
  process.once(name, listener);
  return $std_core_types.Ok(() => {
    if (done) return;
    done = true;
    clearInterval(keep);
    process.removeListener(name, listener);
  });
}

export function kk_signal_watch( evloop, code, cb ) {
  const name = _signal_name(code);
  if (name === null) return $std_core_exn._error_from_exception(new Error("signal not supported on this platform"));
  // keep Node's event loop alive while the signal is watched (as libuv does)
  const keep = setInterval(() => {}, 1 << 30);
  let done = false;
  const listener = () => { if (!done) cb(); };
  process.on(name, listener);
  return $std_core_types.Ok(() => {
    if (done) return;
    done = true;
    clearInterval(keep);
    process.removeListener(name, listener);
  });
}

export function kk_signal_raise( code ) {
  const name = _signal_name(code);
  if (name === null) return $std_core_exn._error_from_exception(new Error("signal not supported on this platform"));
  try {
    process.kill(process.pid, name);
    return $std_core_types.Ok($std_core_types.Unit);
  }
  catch(exn) {
    return $std_core_exn._error_from_exception(exn);
  }
}

export function kk_signal_number( code ) {
  const name = _signal_name(code);
  return (name === null ? -1 : _os_constants.signals[name]);
}
