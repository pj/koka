/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// SQLite bindings on Node's `node:sqlite` (Node 22.5 and later). Node runs
// statements as a whole, so a statement collects its parameters and runs
// (or starts iterating) on the first step.
var _sqlite = null;
if ($std_core.host()=="node") {
  try { _sqlite = await import("node:sqlite"); } catch(e) { _sqlite = null; }
}

function _msg( e ) { return (e && e.message) ? e.message : String(e); }

export function _sqlite_open( path ) {
  const d = { db: null, err: "", changes: 0, rowid: 0n };
  try {
    if (!_sqlite) throw new Error("std/db/sqlite needs Node.js 22.5 or later");
    d.db = new _sqlite.DatabaseSync(path);
  }
  catch(e) { d.err = _msg(e); }
  return d;
}

export function _sqlite_errmsg( d ) { return d.err; }

export function _sqlite_close( d ) {
  if (d.db) { try { d.db.close(); } catch(e) {} d.db = null; }
  return $std_core_types.Unit;
}

export function _sqlite_exec( d, sql ) {
  if (!d.db) return "the database is closed";
  try { d.db.exec(sql); d.err = ""; return ""; }
  catch(e) { d.err = _msg(e); return d.err; }
}

export function _sqlite_prepare( d, sql ) {
  const s = { d: d, st: null, params: [], iter: null, row: null, cols: [] };
  if (!d.db) { d.err = "the database is closed"; return $std_core_types.Tuple2(s, ""); }
  try {
    s.st = d.db.prepare(sql);
    s.st.setReadBigInts(true);
    s.st.setReturnArrays(true);
    s.cols = s.st.columns().map((c) => c.name);
    d.err = "";
  }
  catch(e) { d.err = _msg(e); s.st = null; }
  return $std_core_types.Tuple2(s, "");
}

export function _sqlite_is_null_stmt( s ) { return (s.st === null); }
export function _sqlite_finalize( s ) { s.st = null; s.iter = null; return $std_core_types.Unit; }

function _bind( s, i, v ) { s.params[Number(i) - 1] = v; return 0; }
export function _sqlite_bind_null( s, i ) { return _bind(s, i, null); }
export function _sqlite_bind_int( s, i, v ) { return _bind(s, i, $std_core_types._int_clamp64(v)); }
export function _sqlite_bind_float( s, i, v ) { return _bind(s, i, v); }
export function _sqlite_bind_text( s, i, v ) { return _bind(s, i, v); }
export function _sqlite_bind_blob( s, i, v ) { return _bind(s, i, v); }
// Count the parameters like sqlite3_bind_parameter_count: `?` (numbered after
// the highest so far), `?NNN`, and distinct `:name`, `@name` and `$name`,
// outside of quotes and comments.
export function _sqlite_param_count( s ) {
  if (s.st === null) return 0;
  const sql = s.st.sourceSQL;
  let max = 0, i = 0;
  const named = new Map();
  while (i < sql.length) {
    const c = sql[i];
    if (c === "'" || c === '"' || c === "`" || c === "[") {
      const close = (c === "[" ? "]" : c);
      i++;
      while (i < sql.length && sql[i] !== close) i++;
      i++;
    }
    else if (c === "-" && sql[i + 1] === "-") { while (i < sql.length && sql[i] !== "\n") i++; }
    else if (c === "/" && sql[i + 1] === "*") { const j = sql.indexOf("*/", i + 2); i = (j < 0 ? sql.length : j + 2); }
    else if (c === "?") {
      let j = i + 1;
      while (j < sql.length && sql[j] >= "0" && sql[j] <= "9") j++;
      max = (j > i + 1 ? Math.max(max, Number(sql.slice(i + 1, j))) : max + 1);
      i = j;
    }
    else if ((c === ":" || c === "@" || c === "$") && /[A-Za-z_]/.test(sql[i + 1] || "")) {
      let j = i + 1;
      while (j < sql.length && /[A-Za-z0-9_]/.test(sql[j])) j++;
      const name = sql.slice(i, j);
      if (!named.has(name)) { max++; named.set(name, max); }
      i = j;
    }
    else i++;
  }
  return max;
}

export function _sqlite_step( s ) {
  const d = s.d;
  try {
    if (s.iter === null) {
      if (s.cols.length === 0) {
        const r = s.st.run(...s.params);
        d.changes = Number(r.changes);
        d.rowid = BigInt(r.lastInsertRowid);
        d.err = "";
        return 101;
      }
      s.iter = s.st.iterate(...s.params);
    }
    const n = s.iter.next();
    d.err = "";
    if (n.done) { s.row = null; return 101; }
    s.row = n.value;
    return 100;
  }
  catch(e) { d.err = _msg(e); return 1; }
}

export function _sqlite_column_count( s ) { return s.cols.length; }
export function _sqlite_column_name( s, i ) { return s.cols[Number(i)] || ""; }

export function _sqlite_column_type( s, i ) {
  const v = s.row[Number(i)];
  if (v === null || v === undefined) return 5;
  if (typeof v === "bigint") return 1;
  if (typeof v === "number") return 2;
  if (typeof v === "string") return 3;
  return 4;
}

export function _sqlite_column_int( s, i ) {
  const v = s.row[Number(i)];
  return $std_core_types._int_from_int64(typeof v === "bigint" ? v : BigInt(Math.trunc(Number(v))));
}
export function _sqlite_column_float( s, i ) { return Number(s.row[Number(i)]); }
export function _sqlite_column_text( s, i ) { return String(s.row[Number(i)]); }
export function _sqlite_column_blob( s, i ) {
  const v = s.row[Number(i)];
  return (v instanceof Uint8Array ? v : new Uint8Array(0));
}

export function _sqlite_changes( d ) { return d.changes; }
export function _sqlite_last_rowid( d ) { return $std_core_types._int_from_int64(d.rowid); }

export function _sqlite_version() {
  if (!_sqlite) return "";
  const db = new _sqlite.DatabaseSync(":memory:");
  const v = db.prepare("select sqlite_version() as v").get().v;
  db.close();
  return v;
}
