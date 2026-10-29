/*---------------------------------------------------------------------------
  Copyright 2020-2021, Microsoft Research, Daan Leijen.
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Persistent maps with integer keys.

   An `:imap<v>` is a `:map<int,v>`; all operations of `std/data/map` apply.
*/
module std/data/imap

pub import std/data/map

// A persistent map from integers to values.
pub alias imap<v> = map<int,v>
