/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Persistent hash sets.

   A `:hashset<a>` is a set of elements using the implicit `?hash` and `?(==)`
   functions of the element type (see `std/data/hash`). Iteration order follows
   the hash values: deterministic but otherwise arbitrary.
*/
module std/data/hashset

pub import std/data/hash
import std/data/hashmap
import std/core/seq

// A persistent hash set.
pub value struct hashset<a>
  elems : hashmap<a,()>

// The empty hash set.
pub fun empty() : hashset<a>
  Hashset(hashmap/empty())

// Create a hash set from a list (duplicates are removed).
pub fun from-list( xs : list<a>, ?hash : a -> e int, ?(==) : (a,a) -> e bool ) : e hashset<a>
  Hashset(xs.foldl(hashmap/empty(), fn(m, x) m.insert(x, ())))

// Is the set empty?
pub fun is-empty( s : hashset<a> ) : bool
  s.elems.is-empty

// The number of elements (_O(1)_).
pub fun length( s : hashset<a> ) : int
  s.elems.length

// Is `x` an element of the set?
pub fun contains( s : hashset<a>, x : a, ?hash : a -> e int, ?(==) : (a,a) -> e bool ) : e bool
  s.elems.contains(x)

// Add an element.
pub fun insert( s : hashset<a>, x : a, ?hash : a -> e int, ?(==) : (a,a) -> e bool ) : e hashset<a>
  Hashset(s.elems.insert(x, ()))

// Remove an element (if present).
pub fun remove( s : hashset<a>, x : a, ?hash : a -> e int, ?(==) : (a,a) -> e bool ) : e hashset<a>
  Hashset(s.elems.remove(x))

// The union of two sets.
pub fun union( s1 : hashset<a>, s2 : hashset<a>, ?hash : a -> e int, ?(==) : (a,a) -> e bool ) : e hashset<a>
  Hashset(hashmap/union(s1.elems, s2.elems))

// The elements that are in both sets.
pub fun intersection( s1 : hashset<a>, s2 : hashset<a>, ?hash : a -> e int, ?(==) : (a,a) -> e bool ) : e hashset<a>
  Hashset(hashmap/intersection(s1.elems, s2.elems))

// The elements of `s1` that are not in `s2`.
pub fun difference( s1 : hashset<a>, s2 : hashset<a>, ?hash : a -> e int, ?(==) : (a,a) -> e bool ) : e hashset<a>
  Hashset(hashmap/difference(s1.elems, s2.elems))

// Is every element of `s1` also in `s2`?
pub fun is-subset-of( s1 : hashset<a>, s2 : hashset<a>, ?hash : a -> e int, ?(==) : (a,a) -> e bool ) : e bool
  s1.length <= s2.length && s1.all(fn(x) s2.contains(x))

// Keep the elements that satisfy the predicate.
pub fun filter( s : hashset<a>, pred : a -> e bool ) : e hashset<a>
  Hashset(s.elems.filter(fn(x, _) pred(x)))

// Fold over the elements (in hash order).
pub fun foldl( s : hashset<a>, z : b, f : (b, a) -> e b ) : e b
  s.elems.foldl(z, fn(acc, x, _) f(acc, x))

// Apply `f` to each element (in hash order).
pub fun foreach( s : hashset<a>, f : a -> e () ) : e ()
  s.elems.foreach(fn(x, _) f(x))

// Do all elements satisfy the predicate?
pub fun all( s : hashset<a>, pred : a -> e bool ) : e bool
  s.elems.all(fn(x, _) pred(x))

// Does any element satisfy the predicate?
pub fun any( s : hashset<a>, pred : a -> e bool ) : e bool
  s.elems.any(fn(x, _) pred(x))

// The elements (in hash order).
pub fun hashset/list( s : hashset<a> ) : list<a>
  s.elems.keys

// The elements as a lazy sequence (in hash order).
pub fun hashset/seq( s : hashset<a> ) : seq<e,a>
  s.elems.seq.map(fst)

// Two sets are equal if they contain the same elements.
pub fun (==)( s1 : hashset<a>, s2 : hashset<a>, ?hash : a -> e int, ?(==) : (a,a) -> e bool ) : e bool
  s1.length == s2.length && s1.is-subset-of(s2)

// Show a hash set as `{x1, x2, ...}` (in hash order).
pub fun show( s : hashset<a>, ?show : a -> e string ) : e string
  "{" ++ s.list.map(show).join(", ") ++ "}"

// Convert a list to a hash set: `[1,2,2].hashset`.
pub fun list/hashset( xs : list<a>, ?hash : a -> e int, ?(==) : (a,a) -> e bool ) : e hashset<a>
  xs.from-list
