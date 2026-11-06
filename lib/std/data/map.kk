/*---------------------------------------------------------------------------
  Copyright 2020-2021, Microsoft Research, Daan Leijen.
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Persistent ordered maps.

   A `:map<k,v>` maps keys of type `k` to values of type `v`. Keys are ordered
   by the implicit `?cmp` comparison, so any type with a `cmp` function
   (like `:int`, `:string`, `:char`, lists, tuples, ...) can be used as a key.

   Maps are immutable: operations return a new map and leave the original
   unchanged. When a map is used uniquely, Koka's reference counting reuses
   the nodes in place, so updating a map in a loop is efficient.

   The implementation is a weight-balanced binary tree (as in Haskell's
   `Data.Map`), so `lookup`, `insert` and `remove` take _O(log n)_,
   `length` is _O(1)_, and `elem-at` (indexing by position) is _O(log n)_.

   ```
   val m = [(1,"one"),(2,"two")].map/from-list
   m.insert(3,"three").lookup(3)  // Just("three")
   ```
*/
module std/data/map

import std/core/undiv
import std/core/seq

// A persistent map from keys `k` to values `v`, ordered by key.
pub type map<k,v>
  Tip
  Bin( size : int, key : k, value : v, left : map<k,v>, right : map<k,v> )

// ----------------------------------------------------------------------------
// Construction
// ----------------------------------------------------------------------------

// The empty map.
pub fun empty() : map<k,v>
  Tip

// A map with a single entry.
pub fun singleton( k : k, v : v ) : map<k,v>
  Bin(1, k, v, Tip, Tip)

// Create a map from a list of key-value pairs. Later entries override earlier ones.
pub fun from-list( xs : list<(k,v)>, ^?cmp : (k,k) -> e order ) : e map<k,v>
  xs.foldl(Tip, fn(m,(k,v)) m.insert(k,v))

// Create a map from a list of key-value pairs, combining the values of
// duplicate keys with `f(old,new)`.
pub fun from-list-with( xs : list<(k,v)>, f : (v,v) -> e v, ^?cmp : (k,k) -> e order ) : e map<k,v>
  xs.foldl(Tip, fn(m,(k,v)) m.insert-with(k,v,f))

// ----------------------------------------------------------------------------
// Queries
// ----------------------------------------------------------------------------

// Is the map empty?
pub fun is-empty( m : map<k,v> ) : bool
  match m
    Tip -> True
    _   -> False

// The number of entries in the map (_O(1)_).
pub fun length( m : map<k,v> ) : int
  match m
    Tip -> 0
    Bin(s) -> s

// Look up the value associated with key `k`.
pub fun lookup( m : map<k,v>, k : k, ^?cmp : (k,k) -> e order ) : e maybe<v>
  match m
    Tip -> Nothing
    Bin(_, kx, x, l, r) -> match cmp(k, kx)
      Lt -> lookup(l, k)
      Gt -> lookup(r, k)
      Eq -> Just(x)

// Look up the value associated with key `k`, or return `default` if it is not present.
pub fun lookup-default( m : map<k,v>, k : k, default : v, ^?cmp : (k,k) -> e order ) : e v
  match m.lookup(k)
    Just(x) -> x
    Nothing -> default

// Index a map: `m[k]` raises an exception if `k` is not present.
pub fun @index( m : map<k,v>, k : k, ^?cmp : (k,k) -> <exn|e> order ) : <exn|e> v
  match m.lookup(k)
    Just(x) -> x
    Nothing -> throw("std/data/map/@index: key not found")

// Does the map contain key `k`?
pub fun contains( m : map<k,v>, k : k, ^?cmp : (k,k) -> e order ) : e bool
  match m
    Tip -> False
    Bin(_, kx, _, l, r) -> match cmp(k, kx)
      Lt -> contains(l, k)
      Gt -> contains(r, k)
      Eq -> True

// The entry with the largest key strictly smaller than `k`.
pub fun lookup-lt( m : map<k,v>, k : k, ^?cmp : (k,k) -> e order ) : e maybe<(k,v)>
  lookup-lt-acc(m, k, Nothing)

fun lookup-lt-acc( m : map<k,v>, k : k, best : maybe<(k,v)>, ^?cmp : (k,k) -> e order ) : e maybe<(k,v)>
  match m
    Tip -> best
    Bin(_, kx, x, l, r) -> if cmp(kx, k) == Lt then lookup-lt-acc(r, k, Just((kx,x)))
                           else lookup-lt-acc(l, k, best)

// The entry with the smallest key strictly larger than `k`.
pub fun lookup-gt( m : map<k,v>, k : k, ^?cmp : (k,k) -> e order ) : e maybe<(k,v)>
  lookup-gt-acc(m, k, Nothing)

fun lookup-gt-acc( m : map<k,v>, k : k, best : maybe<(k,v)>, ^?cmp : (k,k) -> e order ) : e maybe<(k,v)>
  match m
    Tip -> best
    Bin(_, kx, x, l, r) -> if cmp(kx, k) == Gt then lookup-gt-acc(l, k, Just((kx,x)))
                           else lookup-gt-acc(r, k, best)

// The entry with the largest key smaller than or equal to `k`.
pub fun lookup-le( m : map<k,v>, k : k, ^?cmp : (k,k) -> e order ) : e maybe<(k,v)>
  lookup-le-acc(m, k, Nothing)

fun lookup-le-acc( m : map<k,v>, k : k, best : maybe<(k,v)>, ^?cmp : (k,k) -> e order ) : e maybe<(k,v)>
  match m
    Tip -> best
    Bin(_, kx, x, l, r) -> match cmp(kx, k)
      Lt -> lookup-le-acc(r, k, Just((kx,x)))
      Eq -> Just((kx,x))
      Gt -> lookup-le-acc(l, k, best)

// The entry with the smallest key larger than or equal to `k`.
pub fun lookup-ge( m : map<k,v>, k : k, ^?cmp : (k,k) -> e order ) : e maybe<(k,v)>
  lookup-ge-acc(m, k, Nothing)

fun lookup-ge-acc( m : map<k,v>, k : k, best : maybe<(k,v)>, ^?cmp : (k,k) -> e order ) : e maybe<(k,v)>
  match m
    Tip -> best
    Bin(_, kx, x, l, r) -> match cmp(kx, k)
      Gt -> lookup-ge-acc(l, k, Just((kx,x)))
      Eq -> Just((kx,x))
      Lt -> lookup-ge-acc(r, k, best)

// The entry at position `i` (0-based) in key order.
pub fun elem-at( m : map<k,v>, i : int ) : maybe<(k,v)>
  match m
    Tip -> Nothing
    Bin(_, kx, x, l, r) ->
      val sl = l.length
      if i < sl then elem-at(l, i)
      elif i == sl then Just((kx,x))
      else elem-at(r, i - sl - 1)

// The position (0-based, in key order) of key `k` in the map.
pub fun index-of( m : map<k,v>, k : k, ^?cmp : (k,k) -> e order ) : e maybe<int>
  index-of-acc(m, k, 0)

fun index-of-acc( m : map<k,v>, k : k, offset : int, ^?cmp : (k,k) -> e order ) : e maybe<int>
  match m
    Tip -> Nothing
    Bin(_, kx, _, l, r) -> match cmp(k, kx)
      Lt -> index-of-acc(l, k, offset)
      Gt -> index-of-acc(r, k, offset + l.length + 1)
      Eq -> Just(offset + l.length)

// The entry with the smallest key.
pub fun min( m : map<k,v> ) : maybe<(k,v)>
  match m
    Tip -> Nothing
    Bin(_, kx, x, Tip, _) -> Just((kx,x))
    Bin(_, _, _, l, _) -> min(l)

// The entry with the largest key.
pub fun max( m : map<k,v> ) : maybe<(k,v)>
  match m
    Tip -> Nothing
    Bin(_, kx, x, _, Tip) -> Just((kx,x))
    Bin(_, _, _, _, r) -> max(r)

// ----------------------------------------------------------------------------
// Insertion and deletion
// ----------------------------------------------------------------------------

// Insert a key-value pair, replacing any existing value for that key.
pub fun insert( m : map<k,v>, k : k, v : v, ^?cmp : (k,k) -> e order ) : e map<k,v>
  match m
    Tip -> singleton(k, v)
    Bin(s, kx, x, l, r) -> match cmp(k, kx)
      Lt -> balance-l(kx, x, insert(l, k, v), r)
      Gt -> balance-r(kx, x, l, insert(r, k, v))
      Eq -> Bin(s, k, v, l, r)

// Insert a key-value pair; if the key is already present, the new value is `f(old,new)`.
pub fun insert-with( m : map<k,v>, k : k, v : v, f : (v,v) -> e v, ^?cmp : (k,k) -> e order ) : e map<k,v>
  match m
    Tip -> singleton(k, v)
    Bin(s, kx, x, l, r) -> match cmp(k, kx)
      Lt -> balance-l(kx, x, insert-with(l, k, v, f), r)
      Gt -> balance-r(kx, x, l, insert-with(r, k, v, f))
      Eq -> Bin(s, kx, f(x, v), l, r)

// Remove a key from the map (if present).
pub fun remove( m : map<k,v>, k : k, ^?cmp : (k,k) -> e order ) : e map<k,v>
  match m
    Tip -> Tip
    Bin(_, kx, x, l, r) -> match cmp(k, kx)
      Lt -> balance-r(kx, x, remove(l, k), r)
      Gt -> balance-l(kx, x, l, remove(r, k))
      Eq -> glue(l, r)

// Update the value at key `k` with `f` (if present).
pub fun update( m : map<k,v>, k : k, f : v -> e v, ^?cmp : (k,k) -> e order ) : e map<k,v>
  match m
    Tip -> Tip
    Bin(s, kx, x, l, r) -> match cmp(k, kx)
      Lt -> Bin(s, kx, x, update(l, k, f), r)
      Gt -> Bin(s, kx, x, l, update(r, k, f))
      Eq -> Bin(s, kx, f(x), l, r)

// The general update function: `f` receives the current value (if any) and
// returns the new value, or `Nothing` to remove the key.
//
// `counts.alter(word, fn(mb) Just(mb.default(0) + 1))`
pub fun alter( m : map<k,v>, k : k, f : maybe<v> -> e maybe<v>, ^?cmp : (k,k) -> e order ) : e map<k,v>
  match m
    Tip -> match f(Nothing)
      Nothing -> Tip
      Just(v) -> singleton(k, v)
    Bin(s, kx, x, l, r) -> match cmp(k, kx)
      Lt -> balance(kx, x, alter(l, k, f), r)
      Gt -> balance(kx, x, l, alter(r, k, f))
      Eq -> match f(Just(x))
        Just(v) -> Bin(s, kx, v, l, r)
        Nothing -> glue(l, r)

// Remove the entry with the smallest key.
pub fun remove-min( m : map<k,v> ) : map<k,v>
  match m
    Tip -> Tip
    Bin(_, _, _, Tip, r) -> r
    Bin(_, kx, x, l, r) -> balance-l(kx, x, remove-min(l), r)

// Remove the entry with the largest key.
pub fun remove-max( m : map<k,v> ) : map<k,v>
  match m
    Tip -> Tip
    Bin(_, _, _, l, Tip) -> l
    Bin(_, kx, x, l, r) -> balance-r(kx, x, l, remove-max(r))

// Return the entry with the smallest key and the map without it.
pub fun pop-min( m : map<k,v> ) : maybe<((k,v), map<k,v>)>
  match m.min
    Just(kv) -> Just((kv, m.remove-min))
    Nothing  -> Nothing

// Return the entry with the largest key and the map without it.
pub fun pop-max( m : map<k,v> ) : maybe<((k,v), map<k,v>)>
  match m.max
    Just(kv) -> Just((kv, m.remove-max))
    Nothing  -> Nothing

// ----------------------------------------------------------------------------
// Combining maps
// ----------------------------------------------------------------------------

// Split a map into the entries with keys smaller than `k` and larger than `k`.
pub fun split( m : map<k,v>, k : k, ^?cmp : (k,k) -> e order ) : e (map<k,v>, map<k,v>)
  match m
    Tip -> (Tip, Tip)
    Bin(_, kx, x, l, r) -> match cmp(k, kx)
      Lt ->
        val (lt, gt) = split(l, k)
        (lt, link(kx, x, gt, r))
      Gt ->
        val (lt, gt) = split(r, k)
        (link(kx, x, l, lt), gt)
      Eq -> (l, r)

// Like `split` but also returns the value at `k` (if present).
pub fun split-lookup( m : map<k,v>, k : k, ^?cmp : (k,k) -> e order ) : e (map<k,v>, maybe<v>, map<k,v>)
  match m
    Tip -> (Tip, Nothing, Tip)
    Bin(_, kx, x, l, r) -> match cmp(k, kx)
      Lt ->
        val (lt, found, gt) = split-lookup(l, k)
        (lt, found, link(kx, x, gt, r))
      Gt ->
        val (lt, found, gt) = split-lookup(r, k)
        (link(kx, x, l, lt), found, gt)
      Eq -> (l, Just(x), r)

// The union of two maps. On duplicate keys, the value from `m1` is kept.
pub fun union( m1 : map<k,v>, m2 : map<k,v>, ^?cmp : (k,k) -> e order ) : e map<k,v>
  match m1
    Tip -> m2
    Bin(_, k, x, l1, r1) -> match m2
      Tip -> m1
      _ ->
        val (l2, r2) = m2.split(k)
        link(k, x, union(l1, pretend-decreasing(l2)), union(r1, pretend-decreasing(r2)))

// The union of two maps, combining the values of duplicate keys with `f(v1,v2)`.
pub fun union-with( m1 : map<k,v>, m2 : map<k,v>, f : (v,v) -> e v, ^?cmp : (k,k) -> e order ) : e map<k,v>
  match m1
    Tip -> m2
    Bin(_, k, x, l1, r1) -> match m2
      Tip -> m1
      _ ->
        val (l2, found, r2) = m2.split-lookup(k)
        val v = match found
          Just(y) -> f(x, y)
          Nothing -> x
        link(k, v, union-with(l1, pretend-decreasing(l2), f), union-with(r1, pretend-decreasing(r2), f))

// The union of a list of maps (left-biased).
pub fun unions( ms : list<map<k,v>>, ^?cmp : (k,k) -> e order ) : e map<k,v>
  ms.foldl(Tip, fn(acc, m) union(acc, m))

// The entries of `m1` whose keys are also in `m2`.
pub fun intersection( m1 : map<k,v>, m2 : map<k,w>, ^?cmp : (k,k) -> e order ) : e map<k,v>
  intersection-with(m1, m2, fn(x, _) x)

// The intersection of two maps, combining the values with `f(v1,v2)`.
pub fun intersection-with( m1 : map<k,v>, m2 : map<k,w>, f : (v,w) -> e x, ^?cmp : (k,k) -> e order ) : e map<k,x>
  match m1
    Tip -> Tip
    Bin(_, k, x, l1, r1) -> match m2
      Tip -> Tip
      _ ->
        val (l2, found, r2) = m2.split-lookup(k)
        val l = intersection-with(l1, pretend-decreasing(l2), f)
        val r = intersection-with(r1, pretend-decreasing(r2), f)
        match found
          Just(y) -> link(k, f(x, y), l, r)
          Nothing -> merge(l, r)

// The entries of `m1` whose keys are not in `m2`.
pub fun difference( m1 : map<k,v>, m2 : map<k,w>, ^?cmp : (k,k) -> e order ) : e map<k,v>
  match m1
    Tip -> Tip
    _ -> match m2
      Tip -> m1
      Bin(_, k, _, l2, r2) ->
        val (l1, r1) = m1.split(k)
        merge(difference(pretend-decreasing(l1), l2), difference(pretend-decreasing(r1), r2))

// Is every key of `m1` also a key of `m2`?
pub fun is-submap-of( m1 : map<k,v>, m2 : map<k,w>, ^?cmp : (k,k) -> e order ) : e bool
  m1.length <= m2.length && m1.all(fn(k, _) m2.contains(k))

// ----------------------------------------------------------------------------
// Traversal
// ----------------------------------------------------------------------------

// Fold over the entries in ascending key order.
pub fun foldl( m : map<k,v>, z : a, f : (a, k, v) -> e a ) : e a
  match m
    Tip -> z
    Bin(_, kx, x, l, r) -> foldl(r, f(foldl(l, z, f), kx, x), f)

// Fold over the entries in descending key order.
pub fun foldr( m : map<k,v>, z : a, f : (k, v, a) -> e a ) : e a
  match m
    Tip -> z
    Bin(_, kx, x, l, r) -> foldr(l, f(kx, x, foldr(r, z, f)), f)

// Apply `f` to each entry in ascending key order.
pub fun foreach( m : map<k,v>, f : (k, v) -> e () ) : e ()
  match m
    Tip -> ()
    Bin(_, kx, x, l, r) ->
      foreach(l, f)
      f(kx, x)
      foreach(r, f)

// Apply `f` to each entry in ascending key order, stopping at the first `Just` result.
pub fun foreach-while( m : map<k,v>, f : (k, v) -> e maybe<a> ) : e maybe<a>
  match m
    Tip -> Nothing
    Bin(_, kx, x, l, r) -> match foreach-while(l, f)
      Nothing -> match f(kx, x)
        Nothing -> foreach-while(r, f)
        found -> found
      found -> found

// Transform every value.
pub fun map( m : map<k,v>, f : v -> e w ) : e map<k,w>
  match m
    Tip -> Tip
    Bin(s, kx, x, l, r) -> Bin(s, kx, f(x), map(l, f), map(r, f))

// Transform every value, with access to the key.
pub fun map-kv( m : map<k,v>, f : (k, v) -> e w ) : e map<k,w>
  match m
    Tip -> Tip
    Bin(s, kx, x, l, r) -> Bin(s, kx, f(kx, x), map-kv(l, f), map-kv(r, f))

// Transform the keys. If `f` maps two keys to the same new key, the value of the larger original key is kept.
pub fun map-keys( m : map<k,v>, f : k -> e j, ^?cmp : (j,j) -> e order ) : e map<j,v>
  m.foldl(Tip, fn(acc, k, v) acc.insert(f(k), v))

// Keep the entries that satisfy the predicate.
pub fun filter( m : map<k,v>, pred : (k, v) -> e bool ) : e map<k,v>
  match m
    Tip -> Tip
    Bin(_, kx, x, l, r) ->
      val l' = filter(l, pred)
      val keep = pred(kx, x)
      val r' = filter(r, pred)
      if keep then link(kx, x, l', r') else merge(l', r')

// Transform and filter values at the same time.
pub fun filter-map( m : map<k,v>, f : (k, v) -> e maybe<w> ) : e map<k,w>
  match m
    Tip -> Tip
    Bin(_, kx, x, l, r) ->
      val l' = filter-map(l, f)
      val mb = f(kx, x)
      val r' = filter-map(r, f)
      match mb
        Just(y) -> link(kx, y, l', r')
        Nothing -> merge(l', r')

// Split into the entries that satisfy the predicate and those that do not.
pub fun partition( m : map<k,v>, pred : (k, v) -> e bool ) : e (map<k,v>, map<k,v>)
  match m
    Tip -> (Tip, Tip)
    Bin(_, kx, x, l, r) ->
      val (l1, l2) = partition(l, pred)
      val keep = pred(kx, x)
      val (r1, r2) = partition(r, pred)
      if keep then (link(kx, x, l1, r1), merge(l2, r2))
              else (merge(l1, r1), link(kx, x, l2, r2))

// Do all entries satisfy the predicate?
pub fun all( m : map<k,v>, pred : (k, v) -> e bool ) : e bool
  match m
    Tip -> True
    Bin(_, kx, x, l, r) -> pred(kx, x) && all(l, pred) && all(r, pred)

// Does any entry satisfy the predicate?
pub fun any( m : map<k,v>, pred : (k, v) -> e bool ) : e bool
  match m
    Tip -> False
    Bin(_, kx, x, l, r) -> pred(kx, x) || any(l, pred) || any(r, pred)

// The keys in ascending order.
pub fun keys( m : map<k,v> ) : list<k>
  m.foldr([], fn(k, _, acc) Cons(k, acc))

// The values in ascending key order.
pub fun values( m : map<k,v> ) : list<v>
  m.foldr([], fn(_, v, acc) Cons(v, acc))

// The entries as a list of key-value pairs, in ascending key order.
pub fun map/list( m : map<k,v> ) : list<(k,v)>
  m.foldr([], fn(k, v, acc) Cons((k,v), acc))

// The entries as a lazy sequence, in ascending key order.
pub fun map/seq( m : map<k,v> ) : seq<e,(k,v)>
  seq/suspend(fn() in-order(push-left(m, [])))

// The entries with a key of at least `lo` as a lazy sequence, in ascending
// key order. Finding the first entry takes _O(log n)_.
pub fun seq-from( m : map<k,v>, lo : k, ^?cmp : (k,k) -> e order ) : e seq<e2,(k,v)>
  val stack = push-from(m, lo, [])
  seq/suspend(fn() in-order(stack))

// push the left spine of `m` onto the stack of nodes still to visit
fun push-left( m : map<k,v>, stack : list<map<k,v>> ) : list<map<k,v>>
  match m
    Tip -> stack
    Bin(_, _, _, l) -> push-left(l, Cons(m, stack))

// like `push-left`, but skip the nodes with a key below `lo`
fun push-from( m : map<k,v>, lo : k, stack : list<map<k,v>>, ^?cmp : (k,k) -> e order ) : e list<map<k,v>>
  match m
    Tip -> stack
    Bin(_, kx, _, l, r) -> if cmp(kx, lo) == Lt then push-from(r, lo, stack) else push-from(l, lo, Cons(m, stack))

fun in-order( stack : list<map<k,v>> ) : step<e,(k,v)>
  match stack
    Cons(Bin(_, kx, x, _, r), rest) -> Yield((kx, x), seq/suspend(fn() in-order(pretend-decreasing(push-left(r, rest)))))
    _ -> Done

// ----------------------------------------------------------------------------
// Equality and showing
// ----------------------------------------------------------------------------

// Two maps are equal if they contain the same keys with equal values.
pub fun (==)( m1 : map<k,v>, m2 : map<k,v>, ^?cmp : (k,k) -> e order, ^?(==) : (v,v) -> e bool ) : e bool
  m1.length == m2.length && eq-entries(m1.list, m2.list)

fun eq-entries( xs : list<(k,v)>, ys : list<(k,v)>, ^?cmp : (k,k) -> e order, ^?(==) : (v,v) -> e bool ) : e bool
  match xs
    Cons((kx,x),xx) -> match ys
      Cons((ky,y),yy) -> cmp(kx,ky) == Eq && x == y && eq-entries(xx,yy)
      Nil -> False
    Nil -> ys.is-empty

pub fun (!=)( m1 : map<k,v>, m2 : map<k,v>, ^?cmp : (k,k) -> e order, ^?(==) : (v,v) -> e bool ) : e bool
  !(m1 == m2)

// Show a map as `{k1: v1, k2: v2}`.
pub fun show( m : map<k,v>, ?k/show : k -> e string, ?v/show : v -> e string ) : e string
  "{" ++ m.list.map(fn((k,v)) k.show ++ ": " ++ v.show).join(", ") ++ "}"

// ----------------------------------------------------------------------------
// Balancing (weight-balanced trees, Adams 1993 / Straka 2010: delta=3, ratio=2)
// ----------------------------------------------------------------------------

val delta = 3
val ratio = 2

inline fun bin( k : k, v : v, l : map<k,v>, r : map<k,v> ) : map<k,v>
  Bin(l.length + r.length + 1, k, v, l, r)

// Restore balance after the left subtree may have grown or the right one shrunk (by one).
fun balance-l( k : k, v : v, l : map<k,v>, r : map<k,v> ) : map<k,v>
  balance(k, v, l, r)

// Restore balance after the right subtree may have grown or the left one shrunk (by one).
fun balance-r( k : k, v : v, l : map<k,v>, r : map<k,v> ) : map<k,v>
  balance(k, v, l, r)

// Restore balance when one subtree changed by at most one element.
fun balance( k : k, v : v, l : map<k,v>, r : map<k,v> ) : map<k,v>
  val sl = l.length
  val sr = r.length
  if sl + sr <= 1 then Bin(sl + sr + 1, k, v, l, r)
  elif sr > delta*sl then rotate-l(k, v, l, r)
  elif sl > delta*sr then rotate-r(k, v, l, r)
  else Bin(sl + sr + 1, k, v, l, r)

fun rotate-l( k : k, v : v, l : map<k,v>, r : map<k,v> ) : map<k,v>
  match r
    Bin(_, kr, vr, rl, rr) ->
      if rl.length < ratio*rr.length then bin(kr, vr, bin(k, v, l, rl), rr)  // single rotation
      else match rl
        Bin(_, krl, vrl, rll, rlr) -> bin(krl, vrl, bin(k, v, l, rll), bin(kr, vr, rlr, rr))  // double
        Tip -> bin(k, v, l, r)
    Tip -> bin(k, v, l, r)

fun rotate-r( k : k, v : v, l : map<k,v>, r : map<k,v> ) : map<k,v>
  match l
    Bin(_, kl, vl, ll, lr) ->
      if lr.length < ratio*ll.length then bin(kl, vl, ll, bin(k, v, lr, r))  // single rotation
      else match lr
        Bin(_, klr, vlr, lrl, lrr) -> bin(klr, vlr, bin(kl, vl, ll, lrl), bin(k, v, lrr, r))  // double
        Tip -> bin(k, v, l, r)
    Tip -> bin(k, v, l, r)

fun insert-min( k : k, v : v, m : map<k,v> ) : map<k,v>
  match m
    Tip -> singleton(k, v)
    Bin(_, kx, x, l, r) -> balance(kx, x, insert-min(k, v, l), r)

fun insert-max( k : k, v : v, m : map<k,v> ) : map<k,v>
  match m
    Tip -> singleton(k, v)
    Bin(_, kx, x, l, r) -> balance(kx, x, l, insert-max(k, v, r))

// Join two trees with a key in between (all keys in `l` < `k` < all keys in `r`);
// the trees may have arbitrarily different sizes.
fun link( k : k, v : v, l : map<k,v>, r : map<k,v> ) : map<k,v>
  match l
    Tip -> insert-min(k, v, r)
    Bin(sl, kl, vl, ll, lr) -> match r
      Tip -> insert-max(k, v, l)
      Bin(sr, kr, vr, rl, rr) ->
        if delta*sl < sr then balance(kr, vr, link(k, v, l, pretend-decreasing(rl)), rr)
        elif delta*sr < sl then balance(kl, vl, ll, link(k, v, lr, pretend-decreasing(r)))
        else Bin(sl + sr + 1, k, v, l, r)

// Join two trees (all keys in `l` < all keys in `r`) of arbitrarily different sizes.
fun merge( l : map<k,v>, r : map<k,v> ) : map<k,v>
  match l
    Tip -> r
    Bin(sl, kl, vl, ll, lr) -> match r
      Tip -> l
      Bin(sr, kr, vr, rl, rr) ->
        if delta*sl < sr then balance(kr, vr, merge(l, pretend-decreasing(rl)), rr)
        elif delta*sr < sl then balance(kl, vl, ll, merge(lr, pretend-decreasing(r)))
        else glue(l, r)

// Join two trees that are balanced with respect to each other.
fun glue( l : map<k,v>, r : map<k,v> ) : map<k,v>
  match l
    Tip -> r
    _ -> match r
      Tip -> l
      _ -> if l.length > r.length then
             match l.max
               Just((km, vm)) -> balance(km, vm, l.remove-max, r)
               Nothing -> r
           else
             match r.min
               Just((km, vm)) -> balance(km, vm, l, r.remove-min)
               Nothing -> l

// Check the internal invariants (sizes, balance, and key order); for testing.
pub fun is-valid( m : map<k,v>, ^?cmp : (k,k) -> e order ) : e bool
  m.keys.is-sorted-strict && valid-shape(m)

fun is-sorted-strict( xs : list<k>, ^?cmp : (k,k) -> e order ) : e bool
  match xs
    Cons(x, xx as Cons(y)) -> cmp(x, y) == Lt && is-sorted-strict(xx)
    _ -> True

fun valid-shape( m : map<k,v> ) : bool
  match m
    Tip -> True
    Bin(s, _, _, l, r) ->
      val sl = l.length
      val sr = r.length
      s == sl + sr + 1 && (sl + sr <= 1 || (sl <= delta*sr && sr <= delta*sl)) &&
      valid-shape(l) && valid-shape(r)
