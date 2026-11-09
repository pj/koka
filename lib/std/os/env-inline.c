/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
#include <stdlib.h>

static kk_unit_t kk_os_set_env( kk_string_t name, kk_string_t value, kk_context_t* ctx ) {
  const char* n = kk_string_cbuf_borrow(name, NULL, ctx);
  const char* v = kk_string_cbuf_borrow(value, NULL, ctx);
  #if defined(_WIN32)
  _putenv_s(n, v);
  #else
  setenv(n, v, 1);
  #endif
  kk_string_drop(name, ctx);
  kk_string_drop(value, ctx);
  return kk_Unit;
}

static kk_unit_t kk_os_unset_env( kk_string_t name, kk_context_t* ctx ) {
  const char* n = kk_string_cbuf_borrow(name, NULL, ctx);
  #if defined(_WIN32)
  _putenv_s(n, "");   // an empty value removes the variable
  #else
  unsetenv(n);
  #endif
  kk_string_drop(name, ctx);
  return kk_Unit;
}
