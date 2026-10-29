/*---------------------------------------------------------------------------
  Copyright 2020-2021, Microsoft Research, Daan Leijen.
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Persistent ordered sets.

   A `:set<a>` is a set of elements ordered by the implicit `?cmp` comparison.
   It is implemented on top of `std/data/map` (a weight-balanced tree), so
   `insert`, `remove` and `contains` take _O(log n)_ and `length` is _O(1)_.

   ```
   val s = [3,1,2,3].set/from-list
   s.list                 // [1,2,3]
   s.union([5].set/from-list).contains(5)   // True
   ```
*/
module std/data/set

import std/data/map

// A persistent set of elements ordered by `?cmp`.
pub value struct set<a>
  elems : map<a,()>

// The empty set.
pub fun empty() : set<a>
  Set(map/empty())

// A set with a single element.
pub fun singleton( x : a ) : set<a>
  Set(map/singleton(x, ()))

// Create a set from a list of elements (duplicates are removed).
pub fun from-list( xs : list<a>, ^?cmp : (a,a) -> e order ) : e set<a>
  Set(xs.foldl(map/empty(), fn(m, x) m.insert(x, ())))

// Is the set empty?
pub fun is-empty( s : set<a> ) : bool
  s.elems.is-empty

// The number of elements (_O(1)_).
pub fun length( s : set<a> ) : int
  s.elems.length

// Is `x` an element of the set?
pub fun contains( s : set<a>, x : a, ^?cmp : (a,a) -> e order ) : e bool
  s.elems.contains(x)

// Add an element.
pub fun insert( s : set<a>, x : a, ^?cmp : (a,a) -> e order ) : e set<a>
  Set(s.elems.insert(x, ()))

// Remove an element (if present).
pub fun remove( s : set<a>, x : a, ^?cmp : (a,a) -> e order ) : e set<a>
  Set(s.elems.remove(x))

// The smallest element.
pub fun min( s : set<a> ) : maybe<a>
  s.elems.min.map(fst)

// The largest element.
pub fun max( s : set<a> ) : maybe<a>
  s.elems.max.map(fst)

// Return the smallest element and the set without it.
pub fun pop-min( s : set<a> ) : maybe<(a, set<a>)>
  match s.elems.pop-min
    Just(((x,_), m)) -> Just((x, Set(m)))
    Nothing -> Nothing

// Return the largest element and the set without it.
pub fun pop-max( s : set<a> ) : maybe<(a, set<a>)>
  match s.elems.pop-max
    Just(((x,_), m)) -> Just((x, Set(m)))
    Nothing -> Nothing

// The largest element strictly smaller than `x`.
pub fun lookup-lt( s : set<a>, x : a, ^?cmp : (a,a) -> e order ) : e maybe<a>
  s.elems.lookup-lt(x).map(fst)

// The smallest element strictly larger than `x`.
pub fun lookup-gt( s : set<a>, x : a, ^?cmp : (a,a) -> e order ) : e maybe<a>
  s.elems.lookup-gt(x).map(fst)

// The largest element smaller than or equal to `x`.
pub fun lookup-le( s : set<a>, x : a, ^?cmp : (a,a) -> e order ) : e maybe<a>
  s.elems.lookup-le(x).map(fst)

// The smallest element larger than or equal to `x`.
pub fun lookup-ge( s : set<a>, x : a, ^?cmp : (a,a) -> e order ) : e maybe<a>
  s.elems.lookup-ge(x).map(fst)

// The element at position `i` (0-based) in ascending order.
pub fun elem-at( s : set<a>, i : int ) : maybe<a>
  s.elems.elem-at(i).map(fst)

// The position (0-based) of `x` in ascending order.
pub fun index-of( s : set<a>, x : a, ^?cmp : (a,a) -> e order ) : e maybe<int>
  s.elems.index-of(x)

// The union of two sets.
pub fun union( s1 : set<a>, s2 : set<a>, ^?cmp : (a,a) -> e order ) : e set<a>
  Set(map/union(s1.elems, s2.elems))

// The union of a list of sets.
pub fun unions( ss : list<set<a>>, ^?cmp : (a,a) -> e order ) : e set<a>
  ss.foldl(empty(), fn(acc, s) union(acc, s))

// The elements that are in both sets.
pub fun intersection( s1 : set<a>, s2 : set<a>, ^?cmp : (a,a) -> e order ) : e set<a>
  Set(map/intersection(s1.elems, s2.elems))

// The elements of `s1` that are not in `s2`.
pub fun difference( s1 : set<a>, s2 : set<a>, ^?cmp : (a,a) -> e order ) : e set<a>
  Set(map/difference(s1.elems, s2.elems))

// Is every element of `s1` also in `s2`?
pub fun is-subset-of( s1 : set<a>, s2 : set<a>, ^?cmp : (a,a) -> e order ) : e bool
  s1.elems.is-submap-of(s2.elems)

// Do the sets have no elements in common?
pub fun is-disjoint( s1 : set<a>, s2 : set<a>, ^?cmp : (a,a) -> e order ) : e bool
  intersection(s1, s2).is-empty

// Split a set into the elements smaller than `x` and larger than `x`.
pub fun split( s : set<a>, x : a, ^?cmp : (a,a) -> e order ) : e (set<a>, set<a>)
  val (l, r) = s.elems.split(x)
  (Set(l), Set(r))

// Keep the elements that satisfy the predicate.
pub fun filter( s : set<a>, pred : a -> e bool ) : e set<a>
  Set(s.elems.filter(fn(x, _) pred(x)))

// Split into the elements that satisfy the predicate and those that do not.
pub fun partition( s : set<a>, pred : a -> e bool ) : e (set<a>, set<a>)
  val (l, r) = s.elems.partition(fn(x, _) pred(x))
  (Set(l), Set(r))

// Apply `f` to every element (the result may have fewer elements).
pub fun map( s : set<a>, f : a -> e b, ^?cmp : (b,b) -> e order ) : e set<b>
  Set(s.elems.map-keys(f))

// Fold over the elements in ascending order.
pub fun foldl( s : set<a>, z : b, f : (b, a) -> e b ) : e b
  s.elems.foldl(z, fn(acc, x, _) f(acc, x))

// Fold over the elements in descending order.
pub fun foldr( s : set<a>, z : b, f : (a, b) -> e b ) : e b
  s.elems.foldr(z, fn(x, _, acc) f(x, acc))

// Apply `f` to each element in ascending order.
pub fun foreach( s : set<a>, f : a -> e () ) : e ()
  s.elems.foreach(fn(x, _) f(x))

// Do all elements satisfy the predicate?
pub fun all( s : set<a>, pred : a -> e bool ) : e bool
  s.elems.all(fn(x, _) pred(x))

// Does any element satisfy the predicate?
pub fun any( s : set<a>, pred : a -> e bool ) : e bool
  s.elems.any(fn(x, _) pred(x))

// The elements in ascending order.
pub fun set/list( s : set<a> ) : list<a>
  s.elems.keys

// Two sets are equal if they contain the same elements.
pub fun (==)( s1 : set<a>, s2 : set<a>, ^?cmp : (a,a) -> e order ) : e bool
  s1.length == s2.length && s1.is-subset-of(s2)

pub fun (!=)( s1 : set<a>, s2 : set<a>, ^?cmp : (a,a) -> e order ) : e bool
  !(s1 == s2)

// Compare sets lexicographically by their elements in ascending order.
pub fun cmp( s1 : set<a>, s2 : set<a>, ^?cmp : (a,a) -> e order ) : e order
  list/cmp(s1.list, s2.list)

// Show a set as `{x1, x2, ...}`.
pub fun show( s : set<a>, ?show : a -> e string ) : e string
  "{" ++ s.list.map(show).join(", ") ++ "}"

// Check the internal invariants; for testing.
pub fun is-valid( s : set<a>, ^?cmp : (a,a) -> e order ) : e bool
  s.elems.is-valid

// Convert a list to a set: `[3,1,2].set`.
pub fun list/set( xs : list<a>, ^?cmp : (a,a) -> e order ) : e set<a>
  xs.from-list
