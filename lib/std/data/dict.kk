/*---------------------------------------------------------------------------
  Copyright 2020-2021, Microsoft Research, Daan Leijen.
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Persistent maps with string keys.

   A `:dict<v>` is a `:map<string,v>`; all operations of `std/data/map` apply.
*/
module std/data/dict

pub import std/data/map

// A persistent map from strings to values.
pub alias dict<v> = map<string,v>
