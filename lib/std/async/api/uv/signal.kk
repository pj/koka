/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// Primitive signal bindings (libuv on C, `process` signal events on Node.js);
// see `std/async/os/signal` for the public API.
module uv/signal

import uv/evloop

extern import
  c  file "signal.c"
  js file "signal.js"

// Wait for one delivery of signal `code` (an index into the list of signals
// in `std/async/os/signal`).
pub extern signal-setup( evloop : any, code : int, cb : () -> ioc () ) : ioc error<() -> ioc ()>
  c  "kk_signal_setup"
  js "kk_signal_setup"

// Send signal `code` to the current process.
pub extern signal-raise( code : int ) : ioc error<()>
  c  "kk_signal_raise"
  js "kk_signal_raise"

// The platform's number for signal `code` (or -1 if it has none).
pub extern signal-number( code : int ) : int
  c  "kk_signal_number"
  js "kk_signal_number"
