/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
#include <uv.h>
#include <signal.h>

// The signals in the order of the `signal` type in std/async/os/signal.
static int kk_signal_from_code( int code ) {
  switch (code) {
    case 0: return SIGINT;
    case 1: return SIGTERM;
    #if defined(_WIN32)
    case 2: return SIGBREAK;
    default: return -1;
    #else
    case 2: return SIGHUP;
    case 3: return SIGQUIT;
    case 4: return SIGUSR1;
    case 5: return SIGUSR2;
    case 6: return SIGWINCH;
    case 7: return SIGPIPE;
    case 8: return SIGCHLD;
    default: return -1;
    #endif
  }
}

static void kk_uv_signal_callback(uv_signal_t* s, int signum) {
  kk_unused(signum);
  kk_uv_handle_callback((uv_handle_t*)s);
}

static void kk_uv_signal_dispose(uv_handle_t* h, void* arg, kk_context_t* ctx) {
  kk_unused(arg); kk_unused(ctx);
  uv_signal_stop((uv_signal_t*)h);
  kk_uv_handle_close(h);
}

static kk_std_core_exn__error kk_signal_setup(kk_uv_loop_t loop, kk_integer_t code, kk_function_t cb, kk_context_t* ctx) {
  const int signum = kk_signal_from_code(kk_integer_clamp32(code,ctx));
  if (signum < 0) { kk_function_drop(cb,ctx); return kk_error_from_uv_errno(UV_EINVAL,ctx); }
  uv_signal_t* s;
  int err = kk_uv_handle_create(sizeof(uv_signal_t), cb, (uv_handle_t**)&s, ctx);
  if (err!=0) return kk_error_from_uv_errno(err,ctx);
  err = uv_signal_init(kk_uv_loop(loop,ctx), s);
  if (err!=0) { kk_uv_handle_free((uv_handle_t*)s,ctx); return kk_error_from_uv_errno(err,ctx); }
  err = uv_signal_start_oneshot(s, &kk_uv_signal_callback, signum);
  if (err!=0) { kk_uv_handle_close((uv_handle_t*)s); return kk_error_from_uv_errno(err,ctx); }
  return kk_result_uv_handle_dispose((uv_handle_t*)s,NULL,&kk_uv_signal_dispose,ctx);
}

static kk_std_core_exn__error kk_signal_raise(kk_integer_t code, kk_context_t* ctx) {
  const int signum = kk_signal_from_code(kk_integer_clamp32(code,ctx));
  if (signum < 0) return kk_error_from_uv_errno(UV_EINVAL,ctx);
  const int err = uv_kill(uv_os_getpid(), signum);
  if (err!=0) return kk_error_from_uv_errno(err,ctx);
  return kk_error_ok(kk_unit_box(kk_Unit),ctx);
}

static kk_integer_t kk_signal_number(kk_integer_t code, kk_context_t* ctx) {
  return kk_integer_from_int(kk_signal_from_code(kk_integer_clamp32(code,ctx)),ctx);
}
