/*---------------------------------------------------------------------------
  Copyright 2020-2021, Microsoft Research, Daan Leijen.
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Persistent sets of integers.

   An `:iset` is a `:set<int>`; all operations of `std/data/set` apply.
*/
module std/data/iset

pub import std/data/set

// A persistent set of integers.
pub alias iset = set<int>
