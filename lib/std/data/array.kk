/*---------------------------------------------------------------------------
  Copyright 2020-2026, Microsoft Research, Daan Leijen, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Mutable, growable arrays.

   An `:array<h,a>` lives in the heap `h`: it is updated in place, and its
   operations have the state effects `read<h>`, `write<h>` and `alloc<h>`.
   With `run` the state stays local, so a function using an array can still
   be pure from the outside:

   ```
   import std/data/array

   fun squares( n : int ) : list<int>
     run
       val a = array()
       for(1, n) fn(i) a.push(i * i)
       a.reverse
       a.list

   fun main()
     println(squares(5))   // [25,16,9,4,1]
   ```

   `push` and `pop` take amortized constant time (the storage doubles when it
   is full), and `get` and `set` constant time. `vector` and `list` copy the
   elements out, so later changes to the array do not affect them.
*/
module std/data/array

import std/core/undiv

// A mutable array in heap `h`.
abstract struct array<h,a>
  data : ref<h,vector<a>>   // the storage; only the first `size` entries are used
  size : ref<h,int>

// Set an entry of the vector in `r` in place (the vector is never shared).
inline extern unsafe-set( ^r : ref<h,vector<a>>, i : ssize_t, x : a ) : write<h> ()
  c  "kk_ref_vector_assign_borrow"
  js inline "((#1).value[#2] = #3)"

inline extern unsafe-get( ^v : vector<a>, i : ssize_t ) : a
  c  "kk_vector_at_borrow"
  js inline "(#1)[#2]"

// Read the storage vector. (`!` would add `div` for any element type that
// might refer to the heap, which is every polymorphic element type; that
// guards against tying a knot through the heap, which an array of
// self-referencing functions could still do.)
inline extern unsafe-read( r : ref<h,vector<a>> ) : read<h> vector<a>
  c  inline "kk_vector_unbox(kk_ref_get(#1,kk_context()),kk_context())"
  js inline "(#1).value"

fun storage( a : array<h,a> ) : read<h> vector<a>
  unsafe-read(a.data)

// A new array with room for `capacity` elements before it has to grow.
pub fun array( capacity : int = 8 ) : alloc<h> array<h,a>
  Array(ref(@unsafe-vector(max(1, capacity).ssize_t)), ref(0))

// A new array with the elements of a list.
pub fun list/array( xs : list<a> ) : <alloc<h>,read<h>,write<h>> array<h,a>
  val a = array(xs.length)
  xs.foreach(fn(x) a.push(x))
  a

// A new array with the elements of a vector.
pub fun vector/array( v : vector<a> ) : <alloc<h>,read<h>,write<h>> array<h,a>
  val a = array(v.length)
  v.foreach(fn(x) a.push(x))
  a

// A new array of `n` copies of `x`.
pub fun array-fill( n : int, x : a ) : <alloc<h>,read<h>,write<h>> array<h,a>
  val a = array(n)
  for(1, n) fn(_) a.push(x)
  a

// The number of elements.
pub fun length( a : array<h,a> ) : read<h> int
  !a.size

pub fun is-empty( a : array<h,a> ) : read<h> bool
  !a.size == 0

fun check( a : array<h,a>, i : int ) : <read<h>,exn> ()
  if i < 0 || i >= !a.size then throw("array index " ++ i.show ++ " out of bounds (length " ++ (!a.size).show ++ ")", ExnRange)

// The element at `i` (from 0); raises an exception if `i` is out of bounds.
pub fun get( a : array<h,a>, i : int ) : <read<h>,exn> a
  a.check(i)
  unsafe-get(a.storage, i.ssize_t)

// `a[i]`
pub fun @index( a : array<h,a>, i : int ) : <read<h>,exn> a
  a.get(i)

// The element at `i`, if `i` is in bounds.
pub fun at( a : array<h,a>, i : int ) : read<h> maybe<a>
  if i < 0 || i >= !a.size then Nothing else Just(unsafe-get(a.storage, i.ssize_t))

// Replace the element at `i`; raises an exception if `i` is out of bounds.
pub fun set( a : array<h,a>, i : int, x : a ) : <read<h>,write<h>,exn> ()
  a.check(i)
  unsafe-set(a.data, i.ssize_t, x)

// Update the element at `i` with `f`.
pub fun modify( a : array<h,a>, i : int, f : a -> <read<h>,write<h>,exn|e> a ) : <read<h>,write<h>,exn|e> ()
  a.set(i, f(a.get(i)))

fun capacity( a : array<h,a> ) : read<h> int
  (a.storage).length

// Make room for at least `n` elements.
pub fun reserve( a : array<h,a>, n : int ) : <read<h>,write<h>,alloc<h>> ()
  if n > a.capacity then
    val old = a.storage
    val len = !a.size
    val bigger = @unsafe-vector(n.ssize_t)
    set(a.data, bigger)
    for(0, len - 1) fn(i) unsafe-set(a.data, i.ssize_t, unsafe-get(old, i.ssize_t))

// Add an element at the end.
pub fun push( a : array<h,a>, x : a ) : <read<h>,write<h>,alloc<h>> ()
  val len = !a.size
  if len >= a.capacity then a.reserve(max(8, 2 * len))
  unsafe-set(a.data, len.ssize_t, x)
  set(a.size, len + 1)

// Remove and return the last element.
pub fun pop( a : array<h,a> ) : <read<h>,write<h>> maybe<a>
  val len = !a.size
  if len == 0 then Nothing
  else
    val x = unsafe-get(a.storage, (len - 1).ssize_t)
    set(a.size, len - 1)
    Just(x)

// The last element.
pub fun last( a : array<h,a> ) : read<h> maybe<a>
  a.at(!a.size - 1)

// Remove all elements.
pub fun clear( a : array<h,a> ) : write<h> ()
  set(a.size, 0)

// Insert `x` at position `i` (0 to `length`), moving the later elements up.
pub fun insert( a : array<h,a>, i : int, x : a ) : <read<h>,write<h>,alloc<h>,exn> ()
  val len = !a.size
  if i < 0 || i > len then throw("array insert at " ++ i.show ++ " out of bounds (length " ++ len.show ++ ")", ExnRange)
  a.push(x)
  for-down(len, i + 1) fn(j) unsafe-set(a.data, j.ssize_t, unsafe-get(a.storage, (j - 1).ssize_t))
  unsafe-set(a.data, i.ssize_t, x)

fun for-down( hi : int, lo : int, f : int -> e () ) : e ()
  if hi >= lo then
    f(hi)
    for-down(pretend-decreasing(hi - 1), lo, f)

// Remove and return the element at `i`, moving the later elements down.
pub fun remove-at( a : array<h,a>, i : int ) : <read<h>,write<h>,exn> a
  val x = a.get(i)
  val len = !a.size
  for(i, len - 2) fn(j) unsafe-set(a.data, j.ssize_t, unsafe-get(a.storage, (j + 1).ssize_t))
  set(a.size, len - 1)
  x

// Swap the elements at `i` and `j`.
pub fun swap( a : array<h,a>, i : int, j : int ) : <read<h>,write<h>,exn> ()
  val x = a.get(i)
  a.set(i, a.get(j))
  a.set(j, x)

// Add all elements of a list at the end.
pub fun extend( a : array<h,a>, xs : list<a> ) : <read<h>,write<h>,alloc<h>> ()
  xs.foreach(fn(x) a.push(x))

// Call `f` on every element (in order).
pub fun foreach( a : array<h,a>, f : a -> <read<h>|e> () ) : <read<h>|e> ()
  for(0, !a.size - 1) fn(i) f(unsafe-get(a.storage, i.ssize_t))

// Call `f` on every element and its index.
pub fun foreach-indexed( a : array<h,a>, f : (int, a) -> <read<h>|e> () ) : <read<h>|e> ()
  for(0, !a.size - 1) fn(i) f(i, unsafe-get(a.storage, i.ssize_t))

// Fold the elements from the left.
pub fun foldl( a : array<h,a>, init : b, f : (b, a) -> <read<h>|e> b ) : <read<h>|e> b
  var acc := init
  a.foreach fn(x) acc := f(acc, x)
  acc

// Replace every element `x` with `f(x)`, in place.
pub fun map-in-place( a : array<h,a>, f : a -> <read<h>,write<h>|e> a ) : <read<h>,write<h>|e> ()
  for(0, !a.size - 1) fn(i) unsafe-set(a.data, i.ssize_t, f(unsafe-get(a.storage, i.ssize_t)))

// Sort the elements in place (stable).
pub fun sort( a : array<h,a>, ?cmp : (a, a) -> order ) : <read<h>,write<h>> ()
  val sorted = a.list.sort
  sorted.foreach-indexed(fn(i, x) unsafe-set(a.data, i.ssize_t, x))

// Reverse the elements in place.
pub fun reverse( a : array<h,a> ) : <read<h>,write<h>> ()
  val len = !a.size
  for(0, len / 2 - 1) fn(i)
    val x = unsafe-get(a.storage, i.ssize_t)
    unsafe-set(a.data, i.ssize_t, unsafe-get(a.storage, (len - 1 - i).ssize_t))
    unsafe-set(a.data, (len - 1 - i).ssize_t, x)

// The index of the first element that satisfies `pred`.
pub fun find-index( a : array<h,a>, pred : a -> <read<h>|e> bool ) : <read<h>|e> maybe<int>
  fun go( i : int )
    if i >= !a.size then Nothing
    elif pred(unsafe-get(a.storage, i.ssize_t)) then Just(i)
    else go(pretend-decreasing(i + 1))
  go(0)

// The elements as a list (a copy).
pub fun list( a : array<h,a> ) : read<h> list<a>
  vector/list(a.vector)

// The elements as a vector (a copy).
pub fun array/vector( a : array<h,a> ) : read<h> vector<a>
  copy-out(a.storage, 0, a.length)

fun copy-out( v : vector<a>, start : int, n : int ) : vector<a>
  vector-init-total(n, fn(i) unsafe-get(v, (start + i).ssize_t))

// The elements from `start` (`count` of them, or up to the end), as a vector.
pub fun slice( a : array<h,a>, start : int, count : int = -1 ) : read<h> vector<a>
  val len = !a.size
  val s = start.clamp(0, len)
  val n = if count < 0 || s + count > len then len - s else count
  copy-out(a.storage, s, n)

pub fun show( a : array<h,a>, ?show : a -> string ) : read<h> string
  "array" ++ a.list.show
