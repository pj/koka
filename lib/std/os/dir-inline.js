/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
var _ensure_dir_err;
var _copy_file_prim;
var _list_dir_prim;
var _is_dir_prim;
var _is_file_prim;

if ($std_core.host()=="node")
{
  var fs = await import("fs");

  const _dir_try = function( action ) {
    try {
      return $std_core_types.Ok( action() );
    }
    catch(exn) {
      return $std_core_exn._error_from_exception(exn);
    }
  };
  const unit = () => $std_core_types.Unit;

  _ensure_dir_err = function( path, mode ) {
    return _dir_try( () => { fs.mkdirSync(path, { recursive: true }); return unit(); } );
  };
  _copy_file_prim = function( from, to, preserve_mtime ) {
    return _dir_try( () => {
      fs.copyFileSync(from, to);
      if (preserve_mtime) {
        const st = fs.statSync(from);
        fs.utimesSync(to, st.atime, st.mtime);
      }
      return unit();
    });
  };
  _list_dir_prim = function( dir ) {
    return _dir_try( () => fs.readdirSync(dir) );
  };
  _is_dir_prim = function( path ) {
    try { return fs.statSync(path).isDirectory(); } catch(exn) { return false; }
  };
  _is_file_prim = function( path ) {
    try { return fs.statSync(path).isFile(); } catch(exn) { return false; }
  };
}
else {
  const unsupported = function() {
    return $std_core_exn._error_from_exception(new Error("file system operations are not supported in this host"));
  };
  _ensure_dir_err = unsupported;
  _copy_file_prim = unsupported;
  _list_dir_prim = unsupported;
  _is_dir_prim = function(path) { return false; };
  _is_file_prim = function(path) { return false; };
}
