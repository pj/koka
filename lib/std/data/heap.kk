/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Persistent priority queues (min-heaps).

   A `:heap<a>` keeps its elements ordered by the implicit `?cmp` comparison
   such that the smallest element is always available in _O(1)_.
   `insert` and `merge` take _O(1)_, and `pop-min` takes amortized _O(log n)_.
   For a max-heap, pass a reversed comparison, for example
   `h.insert(x, ?cmp=fn(a,b) cmp(b,a))`, or use `sort-desc`-style keys.

   The implementation is a pairing heap.

   ```
   val h = [5,1,4].heap
   h.pop-min   // Just((1, heap{4,5}))
   ```
*/
module std/data/heap

import std/core/undiv
import std/core/seq

// A persistent min-heap.
pub value struct heap<a>
  root : tree<a>
  size : int

type tree<a>
  Leaf
  Node( x : a, children : list<tree<a>> )

// The empty heap.
pub fun empty() : heap<a>
  Heap(Leaf, 0)

// A heap with a single element.
pub fun singleton( x : a ) : heap<a>
  Heap(Node(x, []), 1)

// Create a heap from a list of elements.
pub fun from-list( xs : list<a>, ^?cmp : (a,a) -> e order ) : e heap<a>
  xs.foldl(empty(), fn(h, x) h.insert(x))

// Convert a list to a heap: `[3,1,2].heap`.
pub fun list/heap( xs : list<a>, ^?cmp : (a,a) -> e order ) : e heap<a>
  from-list(xs)

// Is the heap empty?
pub fun is-empty( h : heap<a> ) : bool
  h.size == 0

// The number of elements (_O(1)_).
pub fun length( h : heap<a> ) : int
  h.size

fun meld( t1 : tree<a>, t2 : tree<a>, ^?cmp : (a,a) -> e order ) : e tree<a>
  match t1
    Leaf -> t2
    Node(x, xs) -> match t2
      Leaf -> t1
      Node(y, ys) -> if cmp(y, x) == Lt then Node(y, Cons(t1, ys)) else Node(x, Cons(t2, xs))

// Two-pass pairing merge of a list of trees.
fun meld-pairs( ts : list<tree<a>>, ^?cmp : (a,a) -> e order ) : e tree<a>
  match ts
    Nil -> Leaf
    Cons(t, Nil) -> t
    Cons(t1, Cons(t2, rest)) -> meld(meld(t1, t2), meld-pairs(rest))

// Insert an element.
pub fun insert( h : heap<a>, x : a, ^?cmp : (a,a) -> e order ) : e heap<a>
  Heap(meld(Node(x, []), h.root), h.size + 1)

// Merge two heaps.
pub fun merge( h1 : heap<a>, h2 : heap<a>, ^?cmp : (a,a) -> e order ) : e heap<a>
  Heap(meld(h1.root, h2.root), h1.size + h2.size)

// The smallest element.
pub fun min( h : heap<a> ) : maybe<a>
  match h.root
    Node(x) -> Just(x)
    Leaf -> Nothing

// Remove the smallest element, returning it and the remaining heap.
pub fun pop-min( h : heap<a>, ^?cmp : (a,a) -> e order ) : e maybe<(a, heap<a>)>
  match h.root
    Node(x, ts) -> Just((x, Heap(meld-pairs(ts), h.size - 1)))
    Leaf -> Nothing

// Remove the smallest element (if any).
pub fun remove-min( h : heap<a>, ^?cmp : (a,a) -> e order ) : e heap<a>
  match h.pop-min
    Just((_, h')) -> h'
    Nothing -> h

// The elements in ascending order (_O(n log n)_).
pub fun heap/list( h : heap<a>, ^?cmp : (a,a) -> e order ) : e list<a>
  match h.pop-min
    Just((x, h')) -> Cons(x, heap/list(pretend-decreasing(h')))
    Nothing -> Nil

// The elements in ascending order, as a lazy sequence. Each element costs
// _O(log n)_ (amortized) when it is reached.
pub fun heap/seq( h : heap<a>, ^?cmp : (a,a) -> <div|e> order ) : seq<e,a>
  seq/unfold(h, fn(h1) h1.pop-min)

// Take the `n` smallest elements in ascending order.
pub fun take( h : heap<a>, n : int, ^?cmp : (a,a) -> e order ) : e list<a>
  if n <= 0 then Nil
  else match h.pop-min
    Just((x, h')) -> Cons(x, take(pretend-decreasing(h'), n - 1))
    Nothing -> Nil

// Fold over the elements in unspecified order.
pub fun foldl( h : heap<a>, z : b, f : (b, a) -> e b ) : e b
  tree-foldl(h.root, z, f)

fun tree-foldl( t : tree<a>, z : b, f : (b, a) -> e b ) : e b
  match t
    Leaf -> z
    Node(x, ts) -> ts.foldl(f(z, x), fn(acc, t') tree-foldl(pretend-decreasing(t'), acc, f))

// Show a heap as `heap[x1, x2, ...]` in ascending order.
pub fun show( h : heap<a>, ?show : a -> e string, ^?cmp : (a,a) -> e order ) : e string
  "heap" ++ h.list.map(show).show-list(id)
