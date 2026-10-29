/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Persistent hash maps.

   A `:hashmap<k,v>` maps keys to values using the implicit `?hash` and `?(==)`
   functions of the key type (see `std/data/hash`). Use a hash map when the key
   type has no ordering, or when comparing keys is expensive (for example long
   strings) and you do not need the entries in key order.

   Entries are kept in buckets indexed by hash in a `:map<int,_>`, so
   operations take _O(log n)_. Iteration order follows the hash values: it is
   deterministic but otherwise arbitrary.
*/
module std/data/hashmap

pub import std/data/hash
import std/data/map

// A persistent hash map.
pub value struct hashmap<k,v>
  buckets : map<int, list<(k,v)>>
  size : int

// The empty hash map.
pub fun empty() : hashmap<k,v>
  Hashmap(map/empty(), 0)

// A hash map with a single entry.
pub fun singleton( k : k, v : v, ?hash : k -> e int ) : e hashmap<k,v>
  Hashmap(map/singleton(hash(k), [(k,v)]), 1)

// Create a hash map from a list of key-value pairs. Later entries override earlier ones.
pub fun from-list( xs : list<(k,v)>, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  xs.foldl(empty(), fn(m, (k,v)) m.insert(k, v))

// Is the hash map empty?
pub fun is-empty( m : hashmap<k,v> ) : bool
  m.size == 0

// The number of entries (_O(1)_).
pub fun length( m : hashmap<k,v> ) : int
  m.size

fun bucket-lookup( b : list<(k,v)>, k : k, ?(==) : (k,k) -> e bool ) : e maybe<v>
  match b
    Cons((kx,x),bb) -> if kx == k then Just(x) else bucket-lookup(bb, k)
    Nil -> Nothing

// returns the new bucket and whether the key was newly added
fun bucket-insert( b : list<(k,v)>, k : k, v : v, f : (v,v) -> e v, ?(==) : (k,k) -> e bool ) : e (list<(k,v)>, bool)
  match b
    Cons((kx,x),bb) ->
      if kx == k then (Cons((kx, f(x,v)), bb), False)
      else
        val (bb', added) = bucket-insert(bb, k, v, f)
        (Cons((kx,x), bb'), added)
    Nil -> ([(k,v)], True)

// Look up the value associated with key `k`.
pub fun lookup( m : hashmap<k,v>, k : k, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e maybe<v>
  match m.buckets.lookup(hash(k))
    Just(b) -> b.bucket-lookup(k)
    Nothing -> Nothing

// Look up the value associated with key `k`, or return `default`.
pub fun lookup-default( m : hashmap<k,v>, k : k, default : v, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e v
  match m.lookup(k)
    Just(x) -> x
    Nothing -> default

// Index a hash map: `m[k]` raises an exception if `k` is not present.
pub fun @index( m : hashmap<k,v>, k : k, ?hash : k -> <exn|e> int, ?(==) : (k,k) -> <exn|e> bool ) : <exn|e> v
  match m.lookup(k)
    Just(x) -> x
    Nothing -> throw("std/data/hashmap/@index: key not found")

// Does the hash map contain key `k`?
pub fun contains( m : hashmap<k,v>, k : k, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e bool
  m.lookup(k).is-just

// Insert a key-value pair, replacing any existing value for that key.
pub fun insert( m : hashmap<k,v>, k : k, v : v, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  m.insert-with(k, v, fn(_, new) new)

// Insert a key-value pair; if the key is present, the new value is `f(old,new)`.
pub fun insert-with( m : hashmap<k,v>, k : k, v : v, f : (v,v) -> e v, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  val h = hash(k)
  match m.buckets.lookup(h)
    Nothing -> Hashmap(m.buckets.insert(h, [(k,v)]), m.size + 1)
    Just(b) ->
      val (b', added) = b.bucket-insert(k, v, f)
      Hashmap(m.buckets.insert(h, b'), if added then m.size + 1 else m.size)

// Remove a key (if present).
pub fun remove( m : hashmap<k,v>, k : k, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  val h = hash(k)
  match m.buckets.lookup(h)
    Nothing -> m
    Just(b) ->
      val b' = b.filter(fn((kx,_)) !(kx == k))
      if b'.length == b.length then m
      elif b'.is-empty then Hashmap(m.buckets.remove(h), m.size - 1)
      else Hashmap(m.buckets.insert(h, b'), m.size - 1)

// Update the value at key `k` with `f` (if present).
pub fun update( m : hashmap<k,v>, k : k, f : v -> e v, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  match m.lookup(k)
    Just(x) -> m.insert(k, f(x))
    Nothing -> m

// The general update function: `f` receives the current value (if any) and
// returns the new value, or `Nothing` to remove the key.
pub fun alter( m : hashmap<k,v>, k : k, f : maybe<v> -> e maybe<v>, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  match f(m.lookup(k))
    Just(v) -> m.insert(k, v)
    Nothing -> m.remove(k)

// The union of two hash maps. On duplicate keys, the value from `m1` is kept.
pub fun union( m1 : hashmap<k,v>, m2 : hashmap<k,v>, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  m1.foldl(m2, fn(acc, k, v) acc.insert(k, v))

// The union of two hash maps, combining values of duplicate keys with `f(v1,v2)`.
pub fun union-with( m1 : hashmap<k,v>, m2 : hashmap<k,v>, f : (v,v) -> e v, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  m1.foldl(m2, fn(acc, k, v) acc.insert-with(k, v, fn(v2, v1) f(v1, v2)))

// The entries of `m1` whose keys are also in `m2`.
pub fun intersection( m1 : hashmap<k,v>, m2 : hashmap<k,w>, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  m1.filter(fn(k, _) m2.contains(k))

// The entries of `m1` whose keys are not in `m2`.
pub fun difference( m1 : hashmap<k,v>, m2 : hashmap<k,w>, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  m1.filter(fn(k, _) !m2.contains(k))

// Fold over all entries (in hash order).
pub fun foldl( m : hashmap<k,v>, z : a, f : (a, k, v) -> e a ) : e a
  m.buckets.foldl(z, fn(acc, _, b) b.foldl(acc, fn(acc2, (k,v)) f(acc2, k, v)))

// Apply `f` to each entry (in hash order).
pub fun foreach( m : hashmap<k,v>, f : (k, v) -> e () ) : e ()
  m.buckets.foreach(fn(_, b) b.foreach(fn((k,v)) f(k, v)))

// Keep the entries that satisfy the predicate.
pub fun filter( m : hashmap<k,v>, pred : (k, v) -> e bool ) : e hashmap<k,v>
  m.filter-map(fn(k, v) if pred(k, v) then Just(v) else Nothing)

// Transform and filter values at the same time.
pub fun filter-map( m : hashmap<k,v>, f : (k, v) -> e maybe<w> ) : e hashmap<k,w>
  var n := 0
  val bs = m.buckets.filter-map fn(_, b)
    val b' = b.flatmap-maybe(fn((k,v)) f(k, v).map(fn(w) (k,w)))
    n := n + b'.length
    if b'.is-empty then Nothing else Just(b')
  Hashmap(bs, n)

// Transform every value.
pub fun map( m : hashmap<k,v>, f : v -> e w ) : e hashmap<k,w>
  Hashmap(m.buckets.map(fn(b) b.map(fn((k,v)) (k, f(v)))), m.size)

// Transform every value, with access to the key.
pub fun map-kv( m : hashmap<k,v>, f : (k, v) -> e w ) : e hashmap<k,w>
  Hashmap(m.buckets.map(fn(b) b.map(fn((k,v)) (k, f(k, v)))), m.size)

// Do all entries satisfy the predicate?
pub fun all( m : hashmap<k,v>, pred : (k, v) -> e bool ) : e bool
  m.buckets.all(fn(_, b) b.all(fn((k,v)) pred(k, v)))

// Does any entry satisfy the predicate?
pub fun any( m : hashmap<k,v>, pred : (k, v) -> e bool ) : e bool
  m.buckets.any(fn(_, b) b.any(fn((k,v)) pred(k, v)))

// The entries as a list (in hash order).
pub fun hashmap/list( m : hashmap<k,v> ) : list<(k,v)>
  m.buckets.values.concat

// The keys (in hash order).
pub fun keys( m : hashmap<k,v> ) : list<k>
  m.list.map(fn((k,_)) k)

// The values (in hash order of their keys).
pub fun values( m : hashmap<k,v> ) : list<v>
  m.list.map(fn((_,v)) v)

// Two hash maps are equal if they contain the same keys with equal values.
pub fun (==)( m1 : hashmap<k,v>, m2 : hashmap<k,v>, ?hash : k -> e int, ?k/(==) : (k,k) -> e bool, ?v/(==) : (v,v) -> e bool ) : e bool
  m1.size == m2.size && m1.all fn(k, v)
    match m2.lookup(k)
      Just(w) -> v == w
      Nothing -> False

// Show a hash map as `{k1: v1, k2: v2}` (in hash order).
pub fun show( m : hashmap<k,v>, ?k/show : k -> e string, ?v/show : v -> e string ) : e string
  "{" ++ m.list.map(fn((k,v)) k.show ++ ": " ++ v.show).join(", ") ++ "}"

// Convert a list of key-value pairs to a hash map: `[("a",1)].hashmap`.
pub fun list/hashmap( xs : list<(k,v)>, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  xs.from-list
