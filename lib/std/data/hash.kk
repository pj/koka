/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Hashing.

   Hash values are non-negative integers in the range `[0, 2^32)`.
   Hash functions are overloaded by type and passed around as the implicit
   parameter `?hash`, just like `?cmp` and `?show`. For example,
   `[(1,"a"),(2,"b")].hash` works through `list/hash`, `tuple2/hash`,
   `int/hash` and `string/hash`.

   For a user defined type, define a `hash` function for it, and use
   `hash-combine` to mix the hashes of its fields:

   ```
   struct point(x : int, y : int)
   fun point/hash( p : point ) : int
     hash-combine(p.x.hash, p.y.hash)
   ```

   The hashes are deterministic (the same on every run and on both the C and
   JavaScript backends). They are based on MurmurHash3 and are _not_
   cryptographically secure, nor protected against hash flooding.
*/
module std/data/hash

import std/core/undiv
import std/num/int32
import std/num/int64
import std/num/float64

extern import
  c  file "hash-inline"
  js file "hash-inline.js"

fip extern mix32( h : int32, k : int32 ) : int32
  c  inline "kk_hash_mix32(#1,#2)"
  js "_hash_mix32"

fip extern fmix32( h : int32 ) : int32
  c  inline "kk_hash_fmix32(#1)"
  js "_hash_fmix32"

extern string-hash32( ^s : string, seed : int32 ) : int32
  c  inline "kk_hash_string32(#1,#2,kk_context())"
  js "_hash_string32"

val seed : int32 = 0x2545_F491.int32

inline fun finish( h : int32 ) : int
  h.fmix32.uint

// Mix an arbitrary precision integer into a hash state.
fun int-mix( h : int32, i : int ) : int32
  if i >= -0x8000_0000 && i <= 0x7FFF_FFFF then mix32(h, i.int32)
  else int-mix( mix32(h, uint32(i % 0x1_0000_0000)), pretend-decreasing(i / 0x1_0000_0000) )

// Combine two hash values into a new hash value. The order matters:
// `hash-combine(a,b)` is generally different from `hash-combine(b,a)`.
pub fun hash-combine( h1 : int, h2 : int ) : int
  mix32(mix32(seed, uint32(h1)), uint32(h2)).finish

// Combine a list of hash values into a single hash value.
pub fun hash-combine-all( hs : list<int> ) : int
  hs.foldl(seed, fn(h,k) mix32(h, uint32(k))).int-mix(hs.length).finish

pub fun int/hash( i : int ) : int
  int-mix(seed, i).finish

pub fun int32/hash( i : int32 ) : int
  i.int.hash

pub fun int64/hash( i : int64 ) : int
  i.int.hash

// note: `noinline` works around an -O1 miscompilation where the inlined
// `c.int` of a character literal was folded to `0`.
pub noinline fun char/hash( c : char ) : int
  int-mix(seed, c.int).finish

pub fun bool/hash( b : bool ) : int
  if b then 1.hash else 0.hash

pub fun unit/hash( _u : () ) : int
  seed.finish

pub fun order/hash( o : order ) : int
  o.int.hash

pub fun string/hash( s : string ) : int
  string-hash32(s, seed).uint

// Hash of a `:float64`; `0.0` and `-0.0` hash the same (as they are equal).
pub fun float64/hash( d : float64 ) : int
  if d == 0.0 then 0.hash else d.float64-to-bits.int.hash

pub fun list/hash( xs : list<a>, ?hash : a -> e int ) : e int
  hash-list-mix(seed, xs, 0)

fun hash-list-mix( h : int32, xs : list<a>, n : int, ?hash : a -> e int ) : e int
  match xs
    Cons(x,xx) -> hash-list-mix( mix32(h, uint32(hash(x))), xx, n+1 )
    Nil -> int-mix(h, n).finish

pub fun vector/hash( v : vector<a>, ?hash : a -> e int ) : e int
  v.list.hash

pub fun maybe/hash( m : maybe<a>, ?hash : a -> e int ) : e int
  match m
    Nothing -> 0x6E6F_6E65.hash
    Just(x) -> hash-combine(1, hash(x))

pub fun either/hash( e : either<a,b>, ?left/hash : a -> e int, ?right/hash : b -> e int ) : e int
  match e
    Left(x)  -> hash-combine(2, left/hash(x))
    Right(y) -> hash-combine(3, right/hash(y))

pub fun tuple2/hash( (a,b) : (a,b), ?fst/hash : a -> e int, ?snd/hash : b -> e int ) : e int
  hash-combine(fst/hash(a), snd/hash(b))

pub fun tuple3/hash( (a,b,c) : (a,b,c), ?fst/hash : a -> e int, ?snd/hash : b -> e int, ?thd/hash : c -> e int ) : e int
  hash-combine-all([fst/hash(a), snd/hash(b), thd/hash(c)])

pub fun tuple4/hash( (a,b,c,d) : (a,b,c,d), ?fst/hash : a -> e int, ?snd/hash : b -> e int, ?thd/hash : c -> e int, ?field4/hash : d -> e int ) : e int
  hash-combine-all([fst/hash(a), snd/hash(b), thd/hash(c), field4/hash(d)])
