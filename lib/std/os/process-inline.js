/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
var _cp = null;
if ($std_core.host()=="node") {
  _cp = await import("child_process");
}

function _proc_error( msg ) {
  return $std_core_exn._error_from_exception(new Error(msg));
}

export function _run_command_error( cmd ) {
  if (!_cp) return _proc_error("running processes is not supported in this host");
  try {
    return $std_core_types.Ok(_cp.execSync(cmd, { encoding: "utf8", stdio: ["inherit","pipe","inherit"] }));
  }
  catch(exn) {
    return $std_core_exn._error_from_exception(exn);
  }
}

export function _run_system( cmd ) {
  if (!_cp) return -1;
  const res = _cp.spawnSync(cmd, { shell: true, stdio: "inherit" });
  return (res.status !== null ? res.status : (res.signal ? 128 + 9 : -1));
}

export function _spawn_prim( cmd, args, input, cwd, env ) {
  if (!_cp) return _proc_error("running processes is not supported in this host");
  const opts = { input: input, maxBuffer: 1024*1024*1024 };
  if (cwd.length > 0) opts.cwd = cwd;
  if (env.length > 0) {
    opts.env = {};
    for (const kv of env) {
      const i = kv.indexOf("=");
      if (i > 0) opts.env[kv.substring(0,i)] = kv.substring(i+1);
    }
  }
  const res = _cp.spawnSync(cmd, args, opts);
  if (res.error) return $std_core_exn._error_from_exception(res.error);
  const code = (res.status !== null ? res.status : 128 + (res.signal === "SIGKILL" ? 9 : 15));
  const bytes = (b) => (b ? new Uint8Array(b.buffer, b.byteOffset, b.length) : new Uint8Array(0));
  return $std_core_types.Ok($std_core_types.Tuple3(code, bytes(res.stdout), bytes(res.stderr)));
}
