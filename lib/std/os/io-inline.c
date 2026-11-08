/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#if defined(_WIN32)
#include <io.h>
#define kk_isatty _isatty
#else
#include <unistd.h>
#define kk_isatty isatty
#endif

static kk_unit_t kk_os_eprint( kk_string_t s, kk_context_t* ctx ) {
  kk_ssize_t len;
  const char* p = kk_string_cbuf_borrow(s,&len,ctx);
  fflush(stdout);  // keep ordering with stdout sensible when both go to a terminal
  fwrite(p, 1, (size_t)len, stderr);
  fflush(stderr);
  kk_string_drop(s,ctx);
  return kk_Unit;
}

static kk_unit_t kk_os_flush( kk_context_t* ctx ) {
  fflush(stdout);
  fflush(stderr);
  return kk_Unit;
}

static kk_std_core_exn__error kk_os_read_stdin( kk_context_t* ctx ) {
  kk_ssize_t cap = 64*1024;
  kk_ssize_t len = 0;
  char* buf = (char*)kk_malloc(cap,ctx);
  size_t n;
  while ((n = fread(buf + len, 1, (size_t)(cap - len), stdin)) > 0) {
    len += (kk_ssize_t)n;
    if (len == cap) {
      cap *= 2;
      buf = (char*)kk_realloc(buf,cap,ctx);
    }
  }
  if (ferror(stdin)) {
    kk_free(buf,ctx);
    return kk_error_from_errno(EIO,ctx);
  }
  kk_string_t s = kk_string_alloc_from_qutf8n(len, buf, ctx);
  kk_free(buf,ctx);
  return kk_error_ok(kk_string_box(s),ctx);
}

static bool kk_os_is_tty( kk_integer_t fd, kk_context_t* ctx ) {
  return (kk_isatty(kk_integer_clamp32(fd,ctx)) != 0);
}

static kk_unit_t kk_os_exit( kk_integer_t code, kk_context_t* ctx ) {
  fflush(stdout);
  fflush(stderr);
  exit(kk_integer_clamp32(code,ctx));
  return kk_Unit;
}

static kk_std_core_exn__error kk_os_read_stdin_chunk( kk_integer_t max, kk_context_t* ctx ) {
  kk_ssize_t n = kk_integer_clamp_ssize_t(max,ctx);
  if (n <= 0) n = 64*1024;
  fflush(stdout);  // show a pending prompt before waiting for input
  uint8_t* buf;
  kk_bytes_t b = kk_bytes_alloc_buf(n, &buf, ctx);
  #if defined(_WIN32)
  const int res = _read(0, buf, (unsigned int)n);
  #else
  ssize_t res;
  do { res = read(0, buf, (size_t)n); } while (res < 0 && errno == EINTR);
  #endif
  if (res < 0) {
    const int err = errno;
    kk_bytes_drop(b,ctx);
    return kk_error_from_errno(err,ctx);
  }
  if (res == 0) {
    kk_bytes_drop(b,ctx);
    return kk_error_ok(kk_bytes_box(kk_bytes_empty()),ctx);
  }
  b = kk_bytes_adjust_length(b, (kk_ssize_t)res, ctx);
  return kk_error_ok(kk_bytes_box(b),ctx);
}

static kk_std_core_exn__error kk_os_write_std( kk_integer_t fd, kk_bytes_t content, kk_context_t* ctx ) {
  FILE* f = (kk_integer_clamp32(fd,ctx) == 2 ? stderr : stdout);
  kk_ssize_t len;
  const uint8_t* p = kk_bytes_buf_borrow(content,&len,ctx);
  if (f == stderr) fflush(stdout);
  int err = 0;
  if (len > 0 && fwrite(p, 1, (size_t)len, f) != (size_t)len) err = (errno != 0 ? errno : EIO);
  if (f == stderr) fflush(stderr);
  kk_bytes_drop(content,ctx);
  if (err != 0) return kk_error_from_errno(err,ctx);
  return kk_error_ok(kk_unit_box(kk_Unit),ctx);
}
