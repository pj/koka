/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Persistent double-ended queues.

   A `:deque<a>` supports adding and removing elements at both ends in
   amortized _O(1)_ time. It also serves as an efficient FIFO queue
   (`push-back` and `pop-front`).

   The implementation is Okasaki's banker's deque: a front list and a
   reversed back list that are rebalanced whenever one becomes more than
   three times as long as the other.
*/
module std/data/deque

// A persistent double-ended queue.
pub value struct deque<a>
  fs : list<a>
  flen : int
  bs : list<a>       // the back, in reverse order
  blen : int

val balance-factor = 3

// The empty deque.
pub fun empty() : deque<a>
  Deque([], 0, [], 0)

// Create a deque from a list (the head of the list becomes the front).
pub fun from-list( xs : list<a> ) : deque<a>
  check(Deque(xs, xs.length, [], 0))

// Convert a list to a deque: `[1,2,3].deque`.
pub fun list/deque( xs : list<a> ) : deque<a>
  from-list(xs)

// Is the deque empty?
pub fun is-empty( d : deque<a> ) : bool
  d.flen + d.blen == 0

// The number of elements (_O(1)_).
pub fun length( d : deque<a> ) : int
  d.flen + d.blen

// Restore the balance invariant between the front and back lists.
fun check( d : deque<a> ) : deque<a>
  val n = d.flen + d.blen
  if d.flen > balance-factor * d.blen + 1 then
    val i = n / 2
    val j = n - i
    Deque(d.fs.take(i), i, d.bs ++ d.fs.drop(i).reverse, j)
  elif d.blen > balance-factor * d.flen + 1 then
    val j = n / 2
    val i = n - j
    Deque(d.fs ++ d.bs.drop(j).reverse, i, d.bs.take(j), j)
  else d

// Add an element at the front.
pub fun push-front( d : deque<a>, x : a ) : deque<a>
  check(Deque(Cons(x, d.fs), d.flen + 1, d.bs, d.blen))

// Add an element at the back.
pub fun push-back( d : deque<a>, x : a ) : deque<a>
  check(Deque(d.fs, d.flen, Cons(x, d.bs), d.blen + 1))

// The first element.
pub fun front( d : deque<a> ) : maybe<a>
  match d.fs
    Cons(x) -> Just(x)
    Nil -> d.bs.head    // at most one element in back

// The last element.
pub fun back( d : deque<a> ) : maybe<a>
  match d.bs
    Cons(x) -> Just(x)
    Nil -> d.fs.head   // at most one element in front

// Remove the first element, returning it and the remaining deque.
pub fun pop-front( d : deque<a> ) : maybe<(a, deque<a>)>
  match d.fs
    Cons(x, xx) -> Just((x, check(Deque(xx, d.flen - 1, d.bs, d.blen))))
    Nil -> match d.bs
      Cons(x) -> Just((x, empty()))
      Nil -> Nothing

// Remove the last element, returning it and the remaining deque.
pub fun pop-back( d : deque<a> ) : maybe<(a, deque<a>)>
  match d.bs
    Cons(x, xx) -> Just((x, check(Deque(d.fs, d.flen, xx, d.blen - 1))))
    Nil -> match d.fs
      Cons(x) -> Just((x, empty()))
      Nil -> Nothing

// The element at position `i` from the front (_O(i)_).
pub fun at( d : deque<a>, i : int ) : maybe<a>
  if i < 0 || i >= d.length then Nothing
  elif i < d.flen then d.fs.drop(i).head
  else d.bs.drop(d.blen - 1 - (i - d.flen)).head

// Concatenate two deques.
pub fun append( d1 : deque<a>, d2 : deque<a> ) : deque<a>
  from-list(d1.list ++ d2.list)

// Reverse the deque (_O(1)_).
pub fun reverse( d : deque<a> ) : deque<a>
  Deque(d.bs, d.blen, d.fs, d.flen)

// The elements from front to back.
pub fun deque/list( d : deque<a> ) : list<a>
  d.fs ++ d.bs.reverse

// Transform every element.
pub fun map( d : deque<a>, f : a -> e b ) : e deque<b>
  val f' = d.fs.map(f)
  val b' = d.bs.reverse.map(f).reverse
  Deque(f', d.flen, b', d.blen)

// Fold from front to back.
pub fun foldl( d : deque<a>, z : b, f : (b, a) -> e b ) : e b
  d.bs.reverse.foldl(d.fs.foldl(z, f), f)

// Apply `f` to each element from front to back.
pub fun foreach( d : deque<a>, f : a -> e () ) : e ()
  d.fs.foreach(f)
  d.bs.reverse.foreach(f)

// Keep the elements that satisfy the predicate.
pub fun filter( d : deque<a>, pred : a -> e bool ) : e deque<a>
  from-list(d.list.filter(pred))

pub fun (==)( d1 : deque<a>, d2 : deque<a>, ?(==) : (a,a) -> e bool ) : e bool
  d1.length == d2.length && d1.list == d2.list

// Show a deque as `deque[x1, x2, ...]`.
pub fun show( d : deque<a>, ?show : a -> e string ) : e string
  "deque" ++ d.list.show
