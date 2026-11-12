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

   A hash map is a hash array mapped trie (HAMT): each level of the tree uses 5
   bits of the 32-bit hash to choose one of up to 32 children, and a bitmap
   records which children are present, so the nodes stay small. A tree of `n`
   entries has a depth of about _log~32~(n)_ (at most 7), and keys whose hashes
   are equal end up together in one collision node. Updates copy only the
   nodes on the path to the key. Iteration order follows the hash values: it
   is deterministic but otherwise arbitrary.
*/
module std/data/hashmap

pub import std/data/hash
import std/num/int32
import std/core/undiv
import std/core/seq

extern import
  c  file "hashmap-inline"
  js file "hashmap-inline.js"

// A node of the trie; an empty `Branch` is the empty map.
type node<k,v>
  Leaf( hash : int32, key : k, value : v )
  // two or more entries whose (full) hashes are equal
  Collision( hash : int32, entries : list<(k,v)> )
  // the children in the order of the bits set in `bitmap`
  Branch( bitmap : int32, children : vector<node<k,v>> )

// A persistent hash map.
pub value struct hashmap<k,v>
  root : node<k,v>
  size : int

inline extern unsafe-get( ^v : vector<a>, i : ssize_t ) : a
  c  "kk_vector_at_borrow"
  js inline "(#1)[#2]"

inline fun nth( v : vector<a>, i : int ) : a
  v.unsafe-get(i.ssize_t)

fun empty-node() : node<k,v>
  Branch(0.int32, vector/empty())

inline fun is-empty-node( n : node<k,v> ) : bool
  match n
    Branch(bm) -> bm == 0.int32
    _ -> False

// the 5 bits of the hash used at `shift` (0, 5, .., 30)
inline fun fragment( h : int32, shift : int ) : int
  h.shr(shift).and(0x1F.int32).int

inline fun bit( frag : int ) : int32
  1.int32.shl(frag)

// the position among the children of the child for `frag`
inline fun child-index( bm : int32, frag : int ) : int
  bm.and(not((-1).int32.shl(frag))).popcount

extern prim-replace-at( v : vector<a>, i : ssize_t, x : a ) : vector<a>
  c  "kk_hamt_replace"
  js "_hamt_replace"

extern prim-insert-at( v : vector<a>, i : ssize_t, x : a ) : vector<a>
  c  "kk_hamt_insert"
  js "_hamt_insert"

extern prim-remove-at( v : vector<a>, i : ssize_t ) : vector<a>
  c  "kk_hamt_remove"
  js "_hamt_remove"

inline fun replace-at( v : vector<a>, i : int, x : a ) : vector<a>
  prim-replace-at(v, i.ssize_t, x)

inline fun insert-at( v : vector<a>, i : int, x : a ) : vector<a>
  prim-insert-at(v, i.ssize_t, x)

inline fun remove-at( v : vector<a>, i : int ) : vector<a>
  prim-remove-at(v, i.ssize_t)

// The empty hash map.
pub fun empty() : hashmap<k,v>
  Hashmap(empty-node(), 0)

// A hash map with a single entry.
pub fun singleton( k : k, v : v, ?hash : k -> e int ) : e hashmap<k,v>
  Hashmap(Leaf(hash(k).uint32, k, v), 1)

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

fun node-lookup( n : node<k,v>, h : int32, shift : int, k : k, ?(==) : (k,k) -> e bool ) : e maybe<v>
  match n
    Leaf(lh, lk, lv) -> if lh == h && lk == k then Just(lv) else Nothing
    Collision(ch, es) -> if ch == h then es.bucket-lookup(k) else Nothing
    Branch(bm, cs) ->
      val frag = h.fragment(shift)
      if bm.and(frag.bit) == 0.int32 then Nothing
      else node-lookup(pretend-decreasing(cs.nth(bm.child-index(frag))), h, shift + 5, k)

// Look up the value associated with key `k`.
pub fun lookup( m : hashmap<k,v>, k : k, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e maybe<v>
  m.root.node-lookup(hash(k).uint32, 0, k)

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

// two nodes with different hashes `h1` and `h2` under one new branch
fun merge( n1 : node<k,v>, h1 : int32, n2 : node<k,v>, h2 : int32, shift : int ) : node<k,v>
  val f1 = h1.fragment(shift)
  val f2 = h2.fragment(shift)
  if f1 == f2 then Branch(f1.bit, [merge(n1, h1, n2, h2, pretend-decreasing(shift + 5))].vector)
  elif f1 < f2 then Branch(f1.bit.or(f2.bit), [n1, n2].vector)
  else Branch(f1.bit.or(f2.bit), [n2, n1].vector)

// returns the new node and whether the key was newly added
fun node-insert( n : node<k,v>, h : int32, shift : int, k : k, v : v, f : (v,v) -> e v, ?(==) : (k,k) -> e bool ) : e (node<k,v>, bool)
  match n
    Leaf(lh, lk, lv) ->
      if lh != h then (merge(n, lh, Leaf(h, k, v), h, shift), True)
      elif lk == k then (Leaf(lh, lk, f(lv, v)), False)
      else (Collision(h, [(lk, lv), (k, v)]), True)
    Collision(ch, es) ->
      if ch != h then (merge(n, ch, Leaf(h, k, v), h, shift), True)
      else
        val (es', added) = es.bucket-insert(k, v, f)
        (Collision(ch, es'), added)
    Branch(bm, cs) ->
      val frag = h.fragment(shift)
      val i = bm.child-index(frag)
      if bm.and(frag.bit) == 0.int32 then (Branch(bm.or(frag.bit), cs.insert-at(i, Leaf(h, k, v))), True)
      else
        val (c', added) = node-insert(pretend-decreasing(cs.nth(i)), h, shift + 5, k, v, f)
        (Branch(bm, cs.replace-at(i, c')), added)

// Insert a key-value pair; if the key is present, the new value is `f(old,new)`.
pub fun insert-with( m : hashmap<k,v>, k : k, v : v, f : (v,v) -> e v, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  val (root, added) = m.root.node-insert(hash(k).uint32, 0, k, v, f)
  Hashmap(root, if added then m.size + 1 else m.size)

// returns `Nothing` if the key is not present
fun node-remove( n : node<k,v>, h : int32, shift : int, k : k, ?(==) : (k,k) -> e bool ) : e maybe<node<k,v>>
  match n
    Leaf(lh, lk) -> if lh == h && lk == k then Just(empty-node()) else Nothing
    Collision(ch, es) ->
      if ch != h then Nothing
      else match es.remove-key(k)
        Nothing -> Nothing
        Just([(k1, v1)]) -> Just(Leaf(ch, k1, v1))
        Just(es') -> Just(Collision(ch, es'))
    Branch(bm, cs) ->
      val frag = h.fragment(shift)
      if bm.and(frag.bit) == 0.int32 then Nothing
      else
        val i = bm.child-index(frag)
        match node-remove(pretend-decreasing(cs.nth(i)), h, shift + 5, k)
          Nothing -> Nothing
          Just(c') ->
            if c'.is-empty-node then
              if cs.length == 1 then Just(empty-node())
              elif cs.length == 2 && !cs.nth(1 - i).is-branch then Just(cs.nth(1 - i))  // a single leaf moves up
              else Just(Branch(bm.and(frag.bit.not), cs.remove-at(i)))
            elif cs.length == 1 && !c'.is-branch then Just(c')
            else Just(Branch(bm, cs.replace-at(i, c')))

fun remove-key( es : list<(k,v)>, k : k, ?(==) : (k,k) -> e bool ) : e maybe<list<(k,v)>>
  match es
    Cons((kx,x),ee) ->
      if kx == k then Just(ee)
      else remove-key(ee, k).map(fn(ee') Cons((kx,x), ee'))
    Nil -> Nothing

// Remove a key (if present).
pub fun remove( m : hashmap<k,v>, k : k, ?hash : k -> e int, ?(==) : (k,k) -> e bool ) : e hashmap<k,v>
  match m.root.node-remove(hash(k).uint32, 0, k)
    Just(root) -> Hashmap(root, m.size - 1)
    Nothing -> m

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

fun node-foldl( n : node<k,v>, z : a, f : (a, k, v) -> e a ) : e a
  match n
    Leaf(_, k, v) -> f(z, k, v)
    Collision(_, es) -> es.foldl(z, fn(acc, (k,v)) f(acc, k, v))
    Branch(_, cs) ->
      var acc := z
      cs.foreach(fn(c) acc := node-foldl(pretend-decreasing(c), acc, f))
      acc

// Fold over all entries (in hash order).
pub fun foldl( m : hashmap<k,v>, z : a, f : (a, k, v) -> e a ) : e a
  m.root.node-foldl(z, f)

// Apply `f` to each entry (in hash order).
pub fun foreach( m : hashmap<k,v>, f : (k, v) -> e () ) : e ()
  m.foldl((), fn(_, k, v) f(k, v))

// Keep the entries that satisfy the predicate.
pub fun filter( m : hashmap<k,v>, pred : (k, v) -> e bool ) : e hashmap<k,v>
  m.filter-map(fn(k, v) if pred(k, v) then Just(v) else Nothing)

// the remaining entries become a node with the shape a sequence of inserts would give
fun node-filter-map( n : node<k,v>, f : (k, v) -> e maybe<w> ) : e (node<k,w>, int)
  match n
    Leaf(h, k, v) ->
      match f(k, v)
        Just(w) -> (Leaf(h, k, w), 1)
        Nothing -> (empty-node(), 0)
    Collision(h, es) ->
      match es.flatmap-maybe(fn((k,v)) f(k, v).map(fn(w) (k,w)))
        [] -> (empty-node(), 0)
        [(k, w)] -> (Leaf(h, k, w), 1)
        es' -> (Collision(h, es'), es'.length)
    Branch(bm, cs) ->
      // the kept children with their bits, in reverse
      var kept := []
      var bits := bm
      var count := 0
      cs.foreach fn(c)
        val b = bits.ctz.bit    // the bit of this child
        bits := bits.xor(b)
        val (c', cn) = node-filter-map(pretend-decreasing(c), f)
        if cn > 0 then
          kept := Cons((b, c'), kept)
          count := count + cn
      match kept
        [] -> (empty-node(), 0)
        [(_, c)] | !c.is-branch -> (c, count)
        _ ->
          val kept' = kept.reverse
          (Branch(kept'.foldl(0.int32, fn(acc, (b, _)) acc.or(b)), kept'.map(snd).vector), count)

// Transform and filter values at the same time.
pub fun filter-map( m : hashmap<k,v>, f : (k, v) -> e maybe<w> ) : e hashmap<k,w>
  val (root, n) = m.root.node-filter-map(f)
  Hashmap(root, n)

fun node-map( n : node<k,v>, f : (k, v) -> e w ) : e node<k,w>
  match n
    Leaf(h, k, v) -> Leaf(h, k, f(k, v))
    Collision(h, es) -> Collision(h, es.map(fn((k,v)) (k, f(k, v))))
    Branch(bm, cs) -> Branch(bm, cs.map(fn(c) node-map(pretend-decreasing(c), f)))

// Transform every value.
pub fun map( m : hashmap<k,v>, f : v -> e w ) : e hashmap<k,w>
  Hashmap(m.root.node-map(fn(_, v) f(v)), m.size)

// Transform every value, with access to the key.
pub fun map-kv( m : hashmap<k,v>, f : (k, v) -> e w ) : e hashmap<k,w>
  Hashmap(m.root.node-map(f), m.size)

fun node-all( n : node<k,v>, pred : (k, v) -> e bool ) : e bool
  match n
    Leaf(_, k, v) -> pred(k, v)
    Collision(_, es) -> es.all(fn((k,v)) pred(k, v))
    Branch(_, cs) -> cs.foreach-while(fn(c) if node-all(pretend-decreasing(c), pred) then Nothing else Just(())).is-nothing

// Do all entries satisfy the predicate?
pub fun all( m : hashmap<k,v>, pred : (k, v) -> e bool ) : e bool
  m.root.node-all(pred)

// Does any entry satisfy the predicate?
pub fun any( m : hashmap<k,v>, pred : (k, v) -> e bool ) : e bool
  !m.root.node-all(fn(k, v) !pred(k, v))

// The entries as a list (in hash order).
pub fun hashmap/list( m : hashmap<k,v> ) : list<(k,v)>
  m.foldl([], fn(acc, k, v) Cons((k,v), acc)).reverse

fun node-seq( n : node<k,v> ) : seq<e,(k,v)>
  match n
    Leaf(_, k, v) -> once((k,v))
    Collision(_, es) -> es.seq
    Branch(_, cs) -> cs.seq.flat-map(fn(c) node-seq(pretend-decreasing(c)))

// The entries as a lazy sequence (in hash order).
pub fun hashmap/seq( m : hashmap<k,v> ) : seq<e,(k,v)>
  m.root.node-seq

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
