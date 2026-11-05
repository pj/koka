/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Lazy sequences and generators.

   A `:seq<e,a>` produces elements of type `a` on demand, performing effect `e`
   to compute each one. Sequences can be infinite: only the elements that a
   consumer asks for are computed.

   ```
   import std/core/seq
   fun main()
     val squares = count-from(1).map(fn(i) i * i)
     println(squares.filter(is-odd).take(5).list)   // [1,9,25,49,81]
   ```

   A sequence can be written as a _generator_: an ordinary function that
   hands out elements with `yield`. The generator only runs up to the next
   `yield` when the consumer asks for another element.

   ```
   fun fib() : seq<e,int>
     generate
       var a := 0
       var b := 1
       while { True }
         yield(a)
         val c = a + b
         a := b
         b := c
   ```

   Sequences are persistent values: a sequence can be traversed more than
   once, and each traversal computes (and performs the effects of) its
   elements again.

   Since a sequence may be infinite, computing its elements may not
   terminate: forcing elements (with `list`, `foldl`, `foreach`, `head`, ...)
   has the `div` effect, and the functions passed to `map`, `filter` and so on
   may diverge too. Building a sequence is lazy and does not force anything.

   When writing down the type of a sequence, keep its effect open (for example
   `seq<e,int>` or `seq<<console|e>,int>`), since effect types in a data type
   are not widened automatically.
*/
module std/core/seq

import std/core
import std/core/undiv

pub infixr 60 (++)

// One step of a sequence: either the end, or the next element and the rest.
pub type step<e::E,a>
  Done
  Yield( head : a, tail : seq<e,a> )

// A lazy, possibly infinite, sequence of elements of type `a` whose
// elements are computed with effect `e` (and `div`).
abstract struct seq<e::E,a>( force : () -> <div|e> step<e,a> )

// Generators produce the elements of a sequence with `yield`.
pub effect yield<a>
  // Produce the next element of the sequence.
  ctl yield( x : a ) : ()

// The sequences built here only allocate closures: they recurse lazily,
// which the termination checker cannot see, hence `pretend-decreasing`.

// ----------------------------------------------------------------------------
// Construction
// ----------------------------------------------------------------------------

// Create a sequence from a function that computes its first step.
pub fun suspend( f : () -> <div|e> step<e,a> ) : seq<e,a>
  Seq(f)

// The empty sequence.
pub fun empty() : seq<e,a>
  Seq(fn() Done)

// A sequence of one element.
pub fun once( x : a ) : seq<e,a>
  Seq(fn() Yield(x, empty()))

// Prepend an element to a sequence.
pub fun cons( x : a, s : seq<e,a> ) : seq<e,a>
  Seq(fn() Yield(x, s))

// Create a sequence from a generator: each `yield` in `gen` produces the
// next element. The generator runs lazily, up to the next `yield`, when the
// next element is demanded.
pub fun generate( gen : () -> <yield<a>,div|e> () ) : seq<e,a>
  Seq fn()
    with handler
      return(_)    Done
      ctl yield(x) Yield(x, Seq(fn() resume(())))
    gen()

// Yield all elements of a sequence from inside a generator.
pub fun yield-all( s : seq<<yield<a>|e>,a> ) : <yield<a>,div|e> ()
  s.foreach(fn(x) yield(x))

// Unfold a sequence from a seed: `f` returns `Nothing` to end the sequence,
// or the next element and the next seed.
pub fun unfold( seed : s, f : s -> <div|e> maybe<(a,s)> ) : seq<e,a>
  Seq fn()
    match f(seed)
      Nothing     -> Done
      Just((x,s)) -> Yield(x, unfold(pretend-decreasing(s), f))

// The infinite sequence `x`, `f(x)`, `f(f(x))`, ...
pub fun iterate( x : a, f : a -> <div|e> a ) : seq<e,a>
  Seq(fn() Yield(x, iterate-next(x, f)))

fun iterate-next( x : a, f : a -> <div|e> a ) : seq<e,a>
  Seq fn()
    val y = f(x)
    Yield(y, iterate-next(pretend-decreasing(y), f))

// The infinite sequence that repeats `x`.
pub fun repeat( x : a ) : seq<e,a>
  Seq(fn() Yield(x, repeat(pretend-decreasing(x))))

// The results of calling `f` again and again.
pub fun repeatedly( f : () -> <div|e> a ) : seq<e,a>
  Seq(fn() Yield(f(), repeatedly(pretend-decreasing(f))))

// Repeat the elements of a sequence forever. The result is empty if `s` is empty.
pub fun cycle( s : seq<e,a> ) : seq<e,a>
  cycle-from(s, s)

fun cycle-from( s : seq<e,a>, whole : seq<e,a> ) : seq<e,a>
  Seq fn()
    match s.force()()
      Yield(x, rest) -> Yield(x, cycle-from(pretend-decreasing(rest), whole))
      Done -> match whole.force()()
        Done -> Done
        Yield(x, rest) -> Yield(x, cycle-from(pretend-decreasing(rest), whole))

// The integers from `lo` up to and including `hi`.
pub fun range( lo : int, hi : int ) : seq<e,int>
  Seq fn()
    if lo > hi then Done else Yield(lo, range(pretend-decreasing(lo + 1), hi))

// The infinite sequence `n`, `n+1`, `n+2`, ...
pub fun count-from( n : int = 0 ) : seq<e,int>
  ints-from(n)

fun ints-from( n : int ) : seq<e,int>
  Seq(fn() Yield(n, ints-from(pretend-decreasing(n + 1))))

// The elements of a list.
pub fun list/seq( xs : list<a> ) : seq<e,a>
  Seq fn()
    match xs
      Nil -> Done
      Cons(x, rest) -> Yield(x, rest.seq)

// The elements of a vector.
pub fun vector/seq( v : vector<a> ) : seq<e,a>
  vector-from(v, 0)

fun vector-from( v : vector<a>, i : int ) : seq<e,a>
  Seq fn()
    match v.at(i)
      Nothing -> Done
      Just(x) -> Yield(x, vector-from(v, pretend-decreasing(i + 1)))

// The characters of a string.
pub fun string/seq( s : string ) : seq<e,char>
  s.slice.seq

// The characters of a string slice.
pub fun sslice/seq( s : sslice ) : seq<e,char>
  Seq fn()
    match s.next
      Nothing -> Done
      Just((c, rest)) -> Yield(c, pretend-decreasing(rest).seq)

// The elements of a `maybe`: one element for `Just`, none for `Nothing`.
pub fun maybe/seq( m : maybe<a> ) : seq<e,a>
  match m
    Nothing -> empty()
    Just(x) -> once(x)

// ----------------------------------------------------------------------------
// Transformation (lazy)
// ----------------------------------------------------------------------------

// Apply `f` to every element.
pub fun map( s : seq<e,a>, f : a -> <div|e> b ) : seq<e,b>
  Seq fn()
    match s.force()()
      Done -> Done
      Yield(x, rest) -> Yield(f(x), pretend-decreasing(rest).map(f))

// Pair every element with its index (starting at `start`, default 0).
pub fun indexed( s : seq<e,a>, start : int = 0 ) : seq<e,(int,a)>
  zip(ints-from(start), s)

// Apply `f` to every element and its index.
pub fun map-indexed( s : seq<e,a>, f : (int, a) -> <div|e> b ) : seq<e,b>
  s.indexed.map(fn((i, x)) f(i, x))

// Run `f` on every element as it passes through, without changing the sequence.
pub fun tap( s : seq<e,a>, f : a -> <div|e> () ) : seq<e,a>
  s.map fn(x)
    f(x)
    x

// Skip elements while `pred` holds, and return the first step after that.
fun skip-while( s : seq<e,a>, pred : a -> <div|e> bool ) : <div|e> step<e,a>
  match s.force()()
    Done -> Done
    Yield(x, rest) -> if pred(x) then rest.skip-while(pred) else Yield(x, rest)

// Keep the elements that satisfy `pred`.
pub fun filter( s : seq<e,a>, pred : a -> <div|e> bool ) : seq<e,a>
  Seq(fn() filter-step(s, pred))

// (All recursion stays in this helper: a `filter` that calls itself from its
// closure sends the -O1 specializer into an endless loop.)
fun filter-step( s : seq<e,a>, pred : a -> <div|e> bool ) : <div|e> step<e,a>
  match s.force()()
    Done -> Done
    Yield(x, rest) ->
      if pred(x) then Yield(x, Seq(fn() filter-step(rest, pred))) else filter-step(rest, pred)

// Remove the elements that satisfy `pred`.
pub fun remove( s : seq<e,a>, pred : a -> <div|e> bool ) : seq<e,a>
  s.filter(fn(x) !pred(x))

// Apply `f` to every element and keep the `Just` results.
pub fun filter-map( s : seq<e,a>, f : a -> <div|e> maybe<b> ) : seq<e,b>
  Seq(fn() filter-map-step(s, f))

fun filter-map-step( s : seq<e,a>, f : a -> <div|e> maybe<b> ) : <div|e> step<e,b>
  match s.force()()
    Done -> Done
    Yield(x, rest) -> match f(x)
      Just(y) -> Yield(y, Seq(fn() filter-map-step(rest, f)))
      Nothing -> filter-map-step(rest, f)

// The first `n` elements.
pub fun take( s : seq<e,a>, n : int ) : seq<e,a>
  Seq fn()
    if n <= 0 then Done else match s.force()()
      Done -> Done
      Yield(x, rest) -> Yield(x, pretend-decreasing(rest).take(n - 1))

// Everything after the first `n` elements.
pub fun drop( s : seq<e,a>, n : int ) : seq<e,a>
  Seq(fn() drop-step(s, n))

fun drop-step( s : seq<e,a>, n : int ) : <div|e> step<e,a>
  if n <= 0 then s.force()() else match s.force()()
    Done -> Done
    Yield(_, rest) -> drop-step(rest, n - 1)

// The longest prefix whose elements satisfy `pred`.
pub fun take-while( s : seq<e,a>, pred : a -> <div|e> bool ) : seq<e,a>
  Seq fn()
    match s.force()()
      Done -> Done
      Yield(x, rest) -> if pred(x) then Yield(x, pretend-decreasing(rest).take-while(pred)) else Done

// Drop the longest prefix whose elements satisfy `pred`.
pub fun drop-while( s : seq<e,a>, pred : a -> <div|e> bool ) : seq<e,a>
  Seq(fn() s.skip-while(pred))

// Every `n`-th element, starting with the first.
pub fun step-by( s : seq<e,a>, n : int ) : seq<e,a>
  Seq fn()
    match s.force()()
      Done -> Done
      Yield(x, rest) -> Yield(x, pretend-decreasing(rest.drop(n - 1)).step-by(n))

// The elements of `s1` followed by the elements of `s2`.
pub fun (++)( s1 : seq<e,a>, s2 : seq<e,a> ) : seq<e,a>
  append(s1, s2)

// The elements of `s1` followed by the elements of `s2`.
pub fun append( s1 : seq<e,a>, s2 : seq<e,a> ) : seq<e,a>
  Seq fn()
    match s1.force()()
      Done -> s2.force()()
      Yield(x, rest) -> Yield(x, append(pretend-decreasing(rest), s2))

// Concatenate a sequence of sequences.
pub fun concat( ss : seq<e,seq<e,a>> ) : seq<e,a>
  Seq(fn() concat-step(ss))

fun concat-step( ss : seq<e,seq<e,a>> ) : <div|e> step<e,a>
  match ss.force()()
    Done -> Done
    Yield(s, rest) -> match s.force()()
      Done -> concat-step(rest)
      Yield(x, more) -> Yield(x, Seq(fn() concat-step(cons(more, rest))))

// Apply `f` to every element and concatenate the resulting sequences.
pub fun flat-map( s : seq<e,a>, f : a -> <div|e> seq<e,b> ) : seq<e,b>
  s.map(f).concat

// Pair up the elements of two sequences; the result ends with the shorter one.
pub fun zip( s1 : seq<e,a>, s2 : seq<e,b> ) : seq<e,(a,b)>
  zip-with(s1, s2, fn(x, y) (x, y))

// Combine the elements of two sequences with `f`; the result ends with the shorter one.
pub fun zip-with( s1 : seq<e,a>, s2 : seq<e,b>, f : (a, b) -> <div|e> c ) : seq<e,c>
  Seq fn()
    match s1.force()()
      Done -> Done
      Yield(x, rest1) -> match s2.force()()
        Done -> Done
        Yield(y, rest2) -> Yield(f(x, y), zip-with(pretend-decreasing(rest1), rest2, f))

// Running accumulation: `init`, `f(init, x1)`, `f(f(init, x1), x2)`, ...
pub fun scan( s : seq<e,a>, init : b, f : (b, a) -> <div|e> b ) : seq<e,b>
  Seq(fn() Yield(init, scan-rest(s, init, f)))

fun scan-rest( s : seq<e,a>, acc : b, f : (b, a) -> <div|e> b ) : seq<e,b>
  Seq fn()
    match s.force()()
      Done -> Done
      Yield(x, rest) ->
        val acc1 = f(acc, x)
        Yield(acc1, pretend-decreasing(rest).scan-rest(acc1, f))

// Split the sequence into lists of `n` elements (the last one may be shorter).
pub fun chunk( s : seq<e,a>, n : int ) : seq<e,list<a>>
  Seq fn()
    val (xs, rest) = s.split-at(max(n, 1))
    if xs.is-nil then Done else Yield(xs, pretend-decreasing(rest).chunk(n))

// Sliding windows of `n` consecutive elements, as lists. A sequence shorter
// than `n` has no windows.
pub fun window( s : seq<e,a>, n : int ) : seq<e,list<a>>
  Seq fn()
    val n1 = max(n, 1)
    val (xs, rest) = s.split-at(n1)
    if xs.length < n1 then Done else Yield(xs, slide(xs, rest))

fun slide( xs : list<a>, s : seq<e,a> ) : seq<e,list<a>>
  Seq fn()
    match s.force()()
      Done -> Done
      Yield(x, rest) ->
        val ys = xs.tail ++ [x]
        Yield(ys, slide(ys, pretend-decreasing(rest)))

// Insert `sep` between consecutive elements.
pub fun intersperse( s : seq<e,a>, sep : a ) : seq<e,a>
  Seq fn()
    match s.force()()
      Done -> Done
      Yield(x, rest) -> Yield(x, pretend-decreasing(rest).prefix-each(sep))

fun prefix-each( s : seq<e,a>, sep : a ) : seq<e,a>
  Seq fn()
    match s.force()()
      Done -> Done
      Yield(x, rest) -> Yield(sep, cons(x, pretend-decreasing(rest).prefix-each(sep)))

// Remove consecutive duplicate elements.
pub fun dedup( s : seq<e,a>, ?(==) : (a, a) -> bool ) : seq<e,a>
  Seq fn()
    match s.force()()
      Done -> Done
      Yield(x, rest) -> Yield(x, pretend-decreasing(rest.drop-while(fn(y) y == x)).dedup)

// ----------------------------------------------------------------------------
// Consumption (forces elements)
// ----------------------------------------------------------------------------

// Compute the first step of the sequence.
pub fun next( s : seq<e,a> ) : <div|e> step<e,a>
  s.force()()

// The first element and the rest of the sequence, or `Nothing` if it is empty.
pub fun uncons( s : seq<e,a> ) : <div|e> maybe<(a,seq<e,a>)>
  match s.force()()
    Done -> Nothing
    Yield(x, rest) -> Just((x, rest))

// The first element, if any.
pub fun head( s : seq<e,a> ) : <div|e> maybe<a>
  match s.force()()
    Done -> Nothing
    Yield(x, _) -> Just(x)

// Is the sequence empty? (Forces the first element.)
pub fun is-empty( s : seq<e,a> ) : <div|e> bool
  match s.force()()
    Done -> True
    _    -> False

// The first `n` elements as a list, and the rest of the sequence.
pub fun split-at( s : seq<e,a>, n : int ) : <div|e> (list<a>, seq<e,a>)
  split-acc(s, n, [])

fun split-acc( s : seq<e,a>, n : int, acc : list<a> ) : <div|e> (list<a>, seq<e,a>)
  if n <= 0 then (acc.reverse, s) else match s.force()()
    Done -> (acc.reverse, s)
    Yield(x, rest) -> split-acc(rest, n - 1, Cons(x, acc))

// All elements as a list.
pub fun list( s : seq<e,a> ) : <div|e> list<a>
  match s.force()()
    Done -> Nil
    Yield(x, rest) -> Cons(x, rest.list)

// All elements as a vector.
pub fun vector( s : seq<e,a> ) : <div|e> vector<a>
  s.list.vector

// Concatenate a sequence of characters into a string.
pub fun char/string( s : seq<e,char> ) : <div|e> string
  s.list.string

// Join a sequence of strings, with `sep` in between.
pub fun join( s : seq<e,string>, sep : string = "" ) : <div|e> string
  s.list.join(sep)

// Call `f` on every element.
pub fun foreach( s : seq<e,a>, f : a -> <div|e> () ) : <div|e> ()
  match s.force()()
    Done -> ()
    Yield(x, rest) ->
      f(x)
      rest.foreach(f)

// Call `f` on every element until it returns `Just`, and return that result.
pub fun foreach-while( s : seq<e,a>, f : a -> <div|e> maybe<b> ) : <div|e> maybe<b>
  match s.force()()
    Done -> Nothing
    Yield(x, rest) -> match f(x)
      Nothing -> rest.foreach-while(f)
      just    -> just

// Call `f` on every element and its index.
pub fun foreach-indexed( s : seq<e,a>, f : (int, a) -> <div|e> () ) : <div|e> ()
  s.indexed.foreach(fn((i, x)) f(i, x))

// Fold the elements from the left.
pub fun foldl( s : seq<e,a>, init : b, f : (b, a) -> <div|e> b ) : <div|e> b
  match s.force()()
    Done -> init
    Yield(x, rest) -> rest.foldl(f(init, x), f)

// The first element that satisfies `pred`.
pub fun find( s : seq<e,a>, pred : a -> <div|e> bool ) : <div|e> maybe<a>
  s.foreach-while(fn(x) if pred(x) then Just(x) else Nothing)

// Apply `f` to the elements and return the first `Just` result.
pub fun find-maybe( s : seq<e,a>, f : a -> <div|e> maybe<b> ) : <div|e> maybe<b>
  s.foreach-while(f)

// Does any element satisfy `pred`? Stops at the first one that does.
pub fun any( s : seq<e,a>, pred : a -> <div|e> bool ) : <div|e> bool
  s.find(pred).is-just

// Do all elements satisfy `pred`? Stops at the first one that does not.
pub fun all( s : seq<e,a>, pred : a -> <div|e> bool ) : <div|e> bool
  s.find(fn(x) !pred(x)).is-nothing

// The number of elements.
pub fun length( s : seq<e,a> ) : <div|e> int
  s.foldl(0, fn(n, _) n + 1)

// The element at index `i` (starting at 0), if there is one.
pub fun at( s : seq<e,a>, i : int ) : <div|e> maybe<a>
  if i < 0 then Nothing else s.drop(i).head

// The last element, if any.
pub fun last( s : seq<e,a> ) : <div|e> maybe<a>
  s.foldl(Nothing, fn(_, x) Just(x))

// The sum of a sequence of integers.
pub fun sum( s : seq<e,int> ) : <div|e> int
  s.foldl(0, fn(x, y) x + y)

// The smallest element, if any (the first one if there are several).
pub fun minimum( s : seq<e,a>, ?cmp : (a, a) -> order ) : <div|e> maybe<a>
  s.foldl(Nothing) fn(m, x)
    match m
      Just(y) | cmp(y, x) != Gt -> m
      _ -> Just(x)

// The largest element, if any (the first one if there are several).
pub fun maximum( s : seq<e,a>, ?cmp : (a, a) -> order ) : <div|e> maybe<a>
  s.foldl(Nothing) fn(m, x)
    match m
      Just(y) | cmp(y, x) != Lt -> m
      _ -> Just(x)

// Show the first 10 elements of a sequence, followed by `,...` if there are more.
pub fun show( s : seq<e,a>, ?show : a -> string ) : <div|e> string
  s.show-prefix(10)

// Show the first `n` elements of a sequence, followed by `,...` if there are more.
pub fun show-prefix( s : seq<e,a>, n : int, ?show : a -> string ) : <div|e> string
  val (xs, rest) = s.split-at(n)
  val more = if rest.is-empty then "" else ",..."
  "seq[" ++ xs.map(show).join(",") ++ more ++ "]"
