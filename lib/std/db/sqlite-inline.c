/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// SQLite bindings: databases and statements are boxed C pointers whose
// finalizers close them.
#include <sqlite3.h>
#include <string.h>

typedef struct kk_sqlite_db_s { sqlite3* db; } kk_sqlite_db_t;
typedef struct kk_sqlite_stmt_s { sqlite3_stmt* stmt; } kk_sqlite_stmt_t;

static void kk_sqlite_db_free( void* p, kk_block_t* block, kk_context_t* ctx ) {
  kk_unused(block);
  kk_sqlite_db_t* d = (kk_sqlite_db_t*)p;
  if (d->db != NULL) sqlite3_close_v2(d->db);
  kk_free(d,ctx);
}

static void kk_sqlite_stmt_free( void* p, kk_block_t* block, kk_context_t* ctx ) {
  kk_unused(block);
  kk_sqlite_stmt_t* s = (kk_sqlite_stmt_t*)p;
  if (s->stmt != NULL) sqlite3_finalize(s->stmt);
  kk_free(s,ctx);
}

static sqlite3* kk_sqlite_db_of( kk_box_t b, kk_context_t* ctx ) {
  return ((kk_sqlite_db_t*)kk_cptr_raw_unbox_borrowed(b,ctx))->db;
}

static sqlite3_stmt* kk_sqlite_stmt_of( kk_box_t b, kk_context_t* ctx ) {
  return ((kk_sqlite_stmt_t*)kk_cptr_raw_unbox_borrowed(b,ctx))->stmt;
}

static kk_string_t kk_sqlite_str( const char* s, kk_context_t* ctx ) {
  return kk_string_alloc_from_qutf8(s == NULL ? "" : s, ctx);
}

// Returns the database, or an empty string as the error message on success... see below.
static kk_box_t kk_sqlite_open( kk_string_t path, kk_context_t* ctx ) {
  kk_sqlite_db_t* d = (kk_sqlite_db_t*)kk_malloc(sizeof(kk_sqlite_db_t),ctx);
  d->db = NULL;
  sqlite3_open_v2(kk_string_cbuf_borrow(path,NULL,ctx), &d->db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, NULL);
  kk_string_drop(path,ctx);
  return kk_cptr_raw_box(&kk_sqlite_db_free, d, ctx);
}

// The last error message ("" if the last call succeeded or there is no database).
static kk_string_t kk_sqlite_errmsg( kk_box_t db, kk_context_t* ctx ) {
  sqlite3* d = kk_sqlite_db_of(db,ctx);
  kk_string_t s;
  if (d == NULL) s = kk_sqlite_str("out of memory", ctx);
  else {
    const int code = sqlite3_errcode(d);
    s = kk_sqlite_str((code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE) ? "" : sqlite3_errmsg(d), ctx);
  }
  kk_box_drop(db,ctx);
  return s;
}

static kk_unit_t kk_sqlite_close( kk_box_t db, kk_context_t* ctx ) {
  kk_sqlite_db_t* d = (kk_sqlite_db_t*)kk_cptr_raw_unbox_borrowed(db,ctx);
  if (d->db != NULL) { sqlite3_close_v2(d->db); d->db = NULL; }
  kk_box_drop(db,ctx);
  return kk_Unit;
}

// Prepare the first statement of `sql`; returns the statement and the rest of the text.
static kk_std_core_types__tuple2 kk_sqlite_prepare( kk_box_t db, kk_string_t sql, kk_context_t* ctx ) {
  sqlite3* d = kk_sqlite_db_of(db,ctx);
  kk_sqlite_stmt_t* s = (kk_sqlite_stmt_t*)kk_malloc(sizeof(kk_sqlite_stmt_t),ctx);
  s->stmt = NULL;
  kk_ssize_t len;
  const char* p = kk_string_cbuf_borrow(sql,&len,ctx);
  const char* tail = p + len;
  if (d != NULL) sqlite3_prepare_v2(d, p, (int)len, &s->stmt, &tail);
  kk_string_t rest = kk_string_alloc_from_qutf8n((kk_ssize_t)(p + len - tail), tail, ctx);
  kk_string_drop(sql,ctx);
  kk_box_drop(db,ctx);
  return kk_std_core_types__new_Tuple2(kk_cptr_raw_box(&kk_sqlite_stmt_free, s, ctx), kk_string_box(rest), ctx);
}

static bool kk_sqlite_is_null_stmt( kk_box_t st, kk_context_t* ctx ) {
  const bool r = (kk_sqlite_stmt_of(st,ctx) == NULL);
  kk_box_drop(st,ctx);
  return r;
}

static kk_unit_t kk_sqlite_finalize( kk_box_t st, kk_context_t* ctx ) {
  kk_sqlite_stmt_t* s = (kk_sqlite_stmt_t*)kk_cptr_raw_unbox_borrowed(st,ctx);
  if (s->stmt != NULL) { sqlite3_finalize(s->stmt); s->stmt = NULL; }
  kk_box_drop(st,ctx);
  return kk_Unit;
}

// Bindings (`i` from 1); return an sqlite result code.
static kk_integer_t kk_sqlite_bind_null( kk_box_t st, kk_integer_t i, kk_context_t* ctx ) {
  const int r = sqlite3_bind_null(kk_sqlite_stmt_of(st,ctx), kk_integer_clamp32(i,ctx));
  kk_box_drop(st,ctx);
  return kk_integer_from_int(r,ctx);
}

static kk_integer_t kk_sqlite_bind_int( kk_box_t st, kk_integer_t i, kk_integer_t v, kk_context_t* ctx ) {
  const int r = sqlite3_bind_int64(kk_sqlite_stmt_of(st,ctx), kk_integer_clamp32(i,ctx), kk_integer_clamp64(v,ctx));
  kk_box_drop(st,ctx);
  return kk_integer_from_int(r,ctx);
}

static kk_integer_t kk_sqlite_bind_float( kk_box_t st, kk_integer_t i, double v, kk_context_t* ctx ) {
  const int r = sqlite3_bind_double(kk_sqlite_stmt_of(st,ctx), kk_integer_clamp32(i,ctx), v);
  kk_box_drop(st,ctx);
  return kk_integer_from_int(r,ctx);
}

static kk_integer_t kk_sqlite_bind_text( kk_box_t st, kk_integer_t i, kk_string_t v, kk_context_t* ctx ) {
  kk_ssize_t len;
  const char* p = kk_string_cbuf_borrow(v,&len,ctx);
  const int r = sqlite3_bind_text(kk_sqlite_stmt_of(st,ctx), kk_integer_clamp32(i,ctx), p, (int)len, SQLITE_TRANSIENT);
  kk_string_drop(v,ctx);
  kk_box_drop(st,ctx);
  return kk_integer_from_int(r,ctx);
}

static kk_integer_t kk_sqlite_bind_blob( kk_box_t st, kk_integer_t i, kk_bytes_t v, kk_context_t* ctx ) {
  kk_ssize_t len;
  const uint8_t* p = kk_bytes_buf_borrow(v,&len,ctx);
  const int r = sqlite3_bind_blob(kk_sqlite_stmt_of(st,ctx), kk_integer_clamp32(i,ctx), (len == 0 ? "" : (const void*)p), (int)len, SQLITE_TRANSIENT);
  kk_bytes_drop(v,ctx);
  kk_box_drop(st,ctx);
  return kk_integer_from_int(r,ctx);
}

static kk_integer_t kk_sqlite_param_count( kk_box_t st, kk_context_t* ctx ) {
  const int n = sqlite3_bind_parameter_count(kk_sqlite_stmt_of(st,ctx));
  kk_box_drop(st,ctx);
  return kk_integer_from_int(n,ctx);
}

// 100: a row, 101: done, otherwise an error code
static kk_integer_t kk_sqlite_step( kk_box_t st, kk_context_t* ctx ) {
  const int r = sqlite3_step(kk_sqlite_stmt_of(st,ctx));
  kk_box_drop(st,ctx);
  return kk_integer_from_int(r,ctx);
}

static kk_integer_t kk_sqlite_column_count( kk_box_t st, kk_context_t* ctx ) {
  const int n = sqlite3_column_count(kk_sqlite_stmt_of(st,ctx));
  kk_box_drop(st,ctx);
  return kk_integer_from_int(n,ctx);
}

static kk_string_t kk_sqlite_column_name( kk_box_t st, kk_integer_t i, kk_context_t* ctx ) {
  kk_string_t s = kk_sqlite_str(sqlite3_column_name(kk_sqlite_stmt_of(st,ctx), kk_integer_clamp32(i,ctx)), ctx);
  kk_box_drop(st,ctx);
  return s;
}

// 1: integer, 2: float, 3: text, 4: blob, 5: null
static kk_integer_t kk_sqlite_column_type( kk_box_t st, kk_integer_t i, kk_context_t* ctx ) {
  const int t = sqlite3_column_type(kk_sqlite_stmt_of(st,ctx), kk_integer_clamp32(i,ctx));
  kk_box_drop(st,ctx);
  return kk_integer_from_int(t,ctx);
}

static kk_integer_t kk_sqlite_column_int( kk_box_t st, kk_integer_t i, kk_context_t* ctx ) {
  const int64_t v = sqlite3_column_int64(kk_sqlite_stmt_of(st,ctx), kk_integer_clamp32(i,ctx));
  kk_box_drop(st,ctx);
  return kk_integer_from_int64(v,ctx);
}

static double kk_sqlite_column_float( kk_box_t st, kk_integer_t i, kk_context_t* ctx ) {
  const double v = sqlite3_column_double(kk_sqlite_stmt_of(st,ctx), kk_integer_clamp32(i,ctx));
  kk_box_drop(st,ctx);
  return v;
}

static kk_string_t kk_sqlite_column_text( kk_box_t st, kk_integer_t i, kk_context_t* ctx ) {
  sqlite3_stmt* s = kk_sqlite_stmt_of(st,ctx);
  const int col = kk_integer_clamp32(i,ctx);
  const unsigned char* p = sqlite3_column_text(s, col);
  const int len = sqlite3_column_bytes(s, col);
  kk_string_t r = kk_string_alloc_from_qutf8n(len, (const char*)(p == NULL ? (const unsigned char*)"" : p), ctx);
  kk_box_drop(st,ctx);
  return r;
}

static kk_bytes_t kk_sqlite_column_blob( kk_box_t st, kk_integer_t i, kk_context_t* ctx ) {
  sqlite3_stmt* s = kk_sqlite_stmt_of(st,ctx);
  const int col = kk_integer_clamp32(i,ctx);
  const void* p = sqlite3_column_blob(s, col);
  const int len = sqlite3_column_bytes(s, col);
  kk_bytes_t r = (len <= 0 || p == NULL ? kk_bytes_empty() : kk_bytes_alloc_dupn(len, (const uint8_t*)p, ctx));
  kk_box_drop(st,ctx);
  return r;
}

static kk_integer_t kk_sqlite_changes( kk_box_t db, kk_context_t* ctx ) {
  sqlite3* d = kk_sqlite_db_of(db,ctx);
  const int64_t n = (d == NULL ? 0 : sqlite3_changes64(d));
  kk_box_drop(db,ctx);
  return kk_integer_from_int64(n,ctx);
}

static kk_integer_t kk_sqlite_last_rowid( kk_box_t db, kk_context_t* ctx ) {
  sqlite3* d = kk_sqlite_db_of(db,ctx);
  const int64_t n = (d == NULL ? 0 : sqlite3_last_insert_rowid(d));
  kk_box_drop(db,ctx);
  return kk_integer_from_int64(n,ctx);
}

static kk_string_t kk_sqlite_version( kk_context_t* ctx ) {
  return kk_sqlite_str(sqlite3_libversion(), ctx);
}

// Run several statements (without results); returns the error message, or "".
static kk_string_t kk_sqlite_exec( kk_box_t db, kk_string_t sql, kk_context_t* ctx ) {
  sqlite3* d = kk_sqlite_db_of(db,ctx);
  char* msg = NULL;
  if (d != NULL) sqlite3_exec(d, kk_string_cbuf_borrow(sql,NULL,ctx), NULL, NULL, &msg);
  kk_string_t r = kk_sqlite_str(d == NULL ? "the database is closed" : msg, ctx);
  if (msg != NULL) sqlite3_free(msg);
  kk_string_drop(sql,ctx);
  kk_box_drop(db,ctx);
  return r;
}
