/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
var _io_fs = null;
var _io_tty = null;
if ($std_core.host()=="node") {
  _io_fs = await import("fs");
  _io_tty = await import("tty");
}

export function _eprint( s ) {
  if (typeof process !== "undefined" && process.stderr) {
    if (_io_fs) _io_fs.writeSync(2, s); else process.stderr.write(s);
  }
  else {
    console.error(s);
  }
  return $std_core_types.Unit;
}

export function _flush() {
  return $std_core_types.Unit;
}

export function _read_stdin() {
  try {
    if (!_io_fs) throw new Error("reading stdin is not supported in this host");
    return $std_core_types.Ok(_io_fs.readFileSync(0, "utf8"));
  }
  catch(exn) {
    if (exn.code === "EAGAIN" || exn.code === "EOF") return $std_core_types.Ok("");
    return $std_core_exn._error_from_exception(exn);
  }
}

export function _is_tty( fd ) {
  return (_io_tty ? _io_tty.isatty(Number(fd)) : false);
}

export function _exit( code ) {
  if (typeof process !== "undefined") process.exit(Number(code));
  return $std_core_types.Unit;
}
