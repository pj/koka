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
