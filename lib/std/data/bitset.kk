/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Dense sets of small non-negative integers.

   A `:bitset` stores one bit per possible element in 64-bit words, so it is
   compact and fast for elements up to a few million. Set operations work a
   word at a time.

   ```
   import std/data/bitset

   fun main()
     val primes = bitset([2, 3, 5, 7, 11, 13])
     val odds = range-bitset(0, 15).filter(is-odd)
     println(primes.intersection(odds).show) // {3,5,7,11,13}
     println((primes - odds).list)      // [2]
     println(primes.count)              // 6
   ```

   Bitsets are persistent values: `insert` and `remove` return a new set
   (copying the words), so build large sets at once with `bitset` or
   `range-bitset`, or combine them with the set operations. Negative
   numbers are never members.
*/
module std/data/bitset

import std/num/int64
import std/core/undiv
import std/core/seq

// A set of non-negative integers, one bit each. The last word is never zero.
abstract value struct bitset( words : vector<int64> )

// The empty set.
pub val empty : bitset = Bitset(vector/empty())

val one64 : int64 = 1.int64
val zero64 : int64 = 0.int64

fun bit( i : int ) : int64
  one64.shl(i % 64)

// Drop trailing zero words.
fun trimmed( ws : vector<int64> ) : bitset
  fun last-nonzero( i : int ) : int
    if i < 0 then -1
    elif ws.at(i).default(zero64) != zero64 then i
    else last-nonzero(pretend-decreasing(i - 1))
  val n = last-nonzero(ws.length - 1) + 1
  if n == ws.length then Bitset(ws) else Bitset(vector-init-total(n, fn(j) ws.at(j).default(zero64)))

fun word( s : bitset, w : int ) : int64
  s.words.at(w).default(zero64)

// The set of the elements of `xs` (negative numbers are left out).
pub fun bitset( xs : list<int> ) : bitset
  val ys = xs.filter(fn(x) x >= 0).sort
  val n = ys.foldl(0, fn(m, x) max(m, x / 64 + 1))
  if n == 0 then empty else Bitset(dense-words(ys, 0, n).vector)

// The words `w` up to `n` for the sorted elements `xs`.
fun dense-words( xs : list<int>, w : int, n : int ) : list<int64>
  if w >= n then []
  else
    val (mine, rest) = xs.span(fn(x) x / 64 == w)
    Cons(mine.foldl(zero64, fn(b, x) b.or(bit(x))), dense-words(rest, pretend-decreasing(w + 1), n))

// The set of the integers from `lo` up to and including `hi`.
pub fun range-bitset( lo : int, hi : int ) : bitset
  val l = max(0, lo)
  if hi < l then empty
  else
    val n = hi / 64 + 1
    val ws = vector-init-total(n) fn(w)
      val base = w * 64
      if base + 63 < l || base > hi then zero64
      else
        val from = max(l, base) - base
        val to = min(hi, base + 63) - base
        // the bits from..to
        val upper = if to == 63 then (0 - 1).int64 else one64.shl(to + 1) - one64
        val lower = one64.shl(from) - one64
        upper.and(lower.not)
    trimmed(ws)

// Is `i` an element?
pub fun member( s : bitset, i : int ) : bool
  i >= 0 && s.word(i / 64).and(bit(i)) != zero64

// Add an element (negative numbers are ignored).
pub fun insert( s : bitset, i : int ) : bitset
  if i < 0 || s.member(i) then s
  else
    val n = max(s.words.length, i / 64 + 1)
    Bitset(vector-init-total(n, fn(w) if w == i / 64 then s.word(w).or(bit(i)) else s.word(w)))

// Remove an element.
pub fun remove( s : bitset, i : int ) : bitset
  if !s.member(i) then s
  else trimmed(vector-init-total(s.words.length, fn(w) if w == i / 64 then s.word(w).and(bit(i).not) else s.word(w)))

// The number of elements.
pub fun count( s : bitset ) : int
  s.words.list.foldl(0, fn(n, w) n + w.popcount)

pub fun is-empty( s : bitset ) : bool
  s.words.length == 0

fun combine( a : bitset, b : bitset, n : int, f : (int64, int64) -> int64 ) : bitset
  trimmed(vector-init-total(n, fn(w) f(a.word(w), b.word(w))))

// The union.
pub fun (+)( a : bitset, b : bitset ) : bitset
  combine(a, b, max(a.words.length, b.words.length), or)

// The elements of `a` that are not in `b`.
pub fun (-)( a : bitset, b : bitset ) : bitset
  combine(a, b, a.words.length, fn(x, y) x.and(y.not))

// The elements in exactly one of `a` and `b`.
pub fun sym-difference( a : bitset, b : bitset ) : bitset
  combine(a, b, max(a.words.length, b.words.length), xor)

pub fun union( a : bitset, b : bitset ) : bitset
  a + b

// The elements in both `a` and `b`.
pub fun intersection( a : bitset, b : bitset ) : bitset
  combine(a, b, min(a.words.length, b.words.length), and)

pub fun difference( a : bitset, b : bitset ) : bitset
  a - b

// The elements from 0 up to, not including, `n` that are not in `s`.
pub fun complement( s : bitset, n : int ) : bitset
  range-bitset(0, n - 1) - s

// Is every element of `a` in `b`?
pub fun is-subset( a : bitset, b : bitset ) : bool
  (a - b).is-empty

// Do `a` and `b` have no element in common?
pub fun is-disjoint( a : bitset, b : bitset ) : bool
  intersection(a, b).is-empty

pub fun (==)( a : bitset, b : bitset ) : bool
  a.words.length == b.words.length && a.words.list.zip(b.words.list).all(fn((x, y)) x == y)

pub fun (!=)( a : bitset, b : bitset ) : bool
  !(a == b)

// The elements of word `w`, from `start` on, in ascending order.
fun word-elems( w : int, bits : int64, acc : list<int> ) : list<int>
  if bits == zero64 then acc
  else
    val low = bits.ctz
    Cons(w * 64 + low, word-elems(w, pretend-decreasing(bits.and(bits - one64)), acc))

// The elements in ascending order.
pub fun list( s : bitset ) : list<int>
  s.words.list.map-indexed(fn(w, bits) word-elems(w, bits, [])).concat

// The elements in ascending order, as a lazy sequence.
pub fun seq( s : bitset ) : seq<e,int>
  s.words.list.seq.indexed.flat-map(fn((w, bits)) word-elems(w, bits, []).seq)

// Call `f` on every element in ascending order.
pub fun foreach( s : bitset, f : int -> e () ) : e ()
  s.list.foreach(f)

// Fold over the elements in ascending order.
pub fun foldl( s : bitset, init : a, f : (a, int) -> e a ) : e a
  s.list.foldl(init, f)

// The elements that satisfy `pred`.
pub fun filter( s : bitset, pred : int -> e bool ) : e bitset
  bitset(s.list.filter(pred))

// The smallest element.
pub fun minimum( s : bitset ) : maybe<int>
  s.next-member(0)

// The largest element.
pub fun maximum( s : bitset ) : maybe<int>
  val n = s.words.length
  if n == 0 then Nothing
  else Just((n - 1) * 64 + 63 - s.word(n - 1).clz)

// The smallest element that is at least `i`.
pub fun next-member( s : bitset, i : int ) : maybe<int>
  val start = max(0, i)
  fun go( w : int, keep : int64 ) : maybe<int>
    if w >= s.words.length then Nothing
    else
      val bits = s.word(w).and(keep)
      if bits != zero64 then Just(w * 64 + bits.ctz)
      else go(pretend-decreasing(w + 1), (0 - 1).int64)
  go(start / 64, (bit(start) - one64).not)

pub fun show( s : bitset ) : string
  "{" ++ s.list.map(show).join(",") ++ "}"
