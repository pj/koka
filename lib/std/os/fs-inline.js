/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
var _read_file_bytes;
var _write_file_bytes;
var _stat_prim;
var _remove_file_prim;
var _rename_prim;
var _chmod_prim;
var _temp_file_prim;
var _create_dir_prim;
var _remove_dir_prim;
var _set_cwd_prim;
var _temp_dir_prim;
var _fd_open;
var _fd_read;
var _fd_write;
var _fd_close;

if ($std_core.host()=="node")
{
  var fs = await import("fs");

  const _fs_try = function( action ) {
    try {
      return $std_core_types.Ok( action() );
    }
    catch(exn) {
      return $std_core_exn._error_from_exception(exn);
    }
  };
  const unit = () => $std_core_types.Unit;

  // create a unique name `prefix` + 6 random characters and pass it to `create` until it succeeds
  const unique = function( prefix, create ) {
    for (let i = 0; i < 100; i++) {
      const name = prefix + Math.random().toString(36).slice(2, 8).padEnd(6, "0");
      try {
        create(name);
        return name;
      }
      catch(exn) {
        if (exn.code !== "EEXIST") throw exn;
      }
    }
    throw new Error("unable to create a unique temporary name");
  };

  _read_file_bytes = function( path ) {
    return _fs_try( () => {
      const buf = fs.readFileSync(path);
      return new Uint8Array(buf.buffer, buf.byteOffset, buf.length);
    });
  };
  _write_file_bytes = function( path, content, append ) {
    return _fs_try( () => {
      if (append) fs.appendFileSync(path, content); else fs.writeFileSync(path, content);
      return unit();
    });
  };
  _stat_prim = function( path, follow ) {
    return _fs_try( () => {
      const st = (follow ? fs.statSync(path) : fs.lstatSync(path));
      const kind = (st.isFile() ? 0 : (st.isDirectory() ? 1 : (st.isSymbolicLink() ? 2 : 3)));
      const ms = st.mtimeMs;
      const secs = Math.floor(ms / 1000);
      const nsecs = Math.round((ms - secs*1000) * 1000000);
      return [kind, st.size, secs, nsecs, st.mode & 0o7777];
    });
  };
  _remove_file_prim = function( path ) {
    return _fs_try( () => { fs.unlinkSync(path); return unit(); } );
  };
  _rename_prim = function( from, to ) {
    return _fs_try( () => { fs.renameSync(from, to); return unit(); } );
  };
  _chmod_prim = function( path, mode ) {
    return _fs_try( () => { fs.chmodSync(path, Number(mode)); return unit(); } );
  };
  _temp_file_prim = function( prefix ) {
    return _fs_try( () => unique(prefix, (name) => fs.closeSync(fs.openSync(name, "wx", 0o600))) );
  };
  _create_dir_prim = function( path ) {
    return _fs_try( () => { fs.mkdirSync(path); return unit(); } );
  };
  _remove_dir_prim = function( path ) {
    return _fs_try( () => { fs.rmdirSync(path); return unit(); } );
  };
  _set_cwd_prim = function( path ) {
    return _fs_try( () => { process.chdir(path); return unit(); } );
  };
  _temp_dir_prim = function( prefix ) {
    return _fs_try( () => fs.mkdtempSync(prefix) );
  };

  // File handles are objects `{ fd }`; closing sets `fd` to -1.
  const badf = function() {
    const exn = new Error("EBADF: file handle is closed");
    exn.code = "EBADF";
    throw exn;
  };
  _fd_open = function( path, mode ) {
    const flags = (mode == 0 ? "r" : (mode == 1 ? "w" : "a"));
    return _fs_try( () => ({ fd: fs.openSync(path, flags) }) );
  };
  _fd_read = function( h, max ) {
    return _fs_try( () => {
      if (h.fd < 0) badf();
      const n = (Number(max) > 0 ? Number(max) : 64*1024);
      const buf = new Uint8Array(n);
      const count = fs.readSync(h.fd, buf, 0, n, null);
      return (count === n ? buf : buf.slice(0, count));
    });
  };
  _fd_write = function( h, content ) {
    return _fs_try( () => {
      if (h.fd < 0) badf();
      let ofs = 0;
      while (ofs < content.length) {
        ofs += fs.writeSync(h.fd, content, ofs, content.length - ofs);
      }
      return unit();
    });
  };
  _fd_close = function( h ) {
    return _fs_try( () => {
      if (h.fd >= 0) {
        const fd = h.fd;
        h.fd = -1;
        fs.closeSync(fd);
      }
      return unit();
    });
  };
}
else {
  const unsupported = function() {
    return $std_core_exn._error_from_exception(new Error("file system operations are not supported in this host"));
  };
  _read_file_bytes = unsupported;
  _write_file_bytes = unsupported;
  _stat_prim = unsupported;
  _remove_file_prim = unsupported;
  _rename_prim = unsupported;
  _chmod_prim = unsupported;
  _temp_file_prim = unsupported;
  _create_dir_prim = unsupported;
  _remove_dir_prim = unsupported;
  _set_cwd_prim = unsupported;
  _temp_dir_prim = unsupported;
  _fd_open = unsupported;
  _fd_read = unsupported;
  _fd_write = unsupported;
  _fd_close = unsupported;
}
