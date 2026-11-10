/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Exact rational numbers.

   ```
   import std/num/rational

   fun main()
     val third = rational(1, 3)
     println(third + rational(1, 6))           // 1/2
     println((third * 3.rational).show)        // 1
     println(rational(22, 7).show-decimal(5))  // 3.14286
     println(parse-rational("-6/8"))           // Just(-3/4)
   ```

   A rational is always kept in lowest terms with a positive denominator, so
   equal numbers have equal representations. As with `:int`, dividing by zero
   gives zero.
*/
module std/num/rational

import std/num/float64
import std/core/undiv

// An exact rational number `num/den`, in lowest terms with `den > 0`.
abstract value struct rational
  num : int
  den : int

fun gcd( a : int, b : int ) : int
  if b.is-zero then a.abs else gcd(pretend-decreasing(b), a % b)

// The rational `n/d`, reduced to lowest terms. A zero denominator gives zero.
pub fun rational( n : int, d : int = 1 ) : rational
  if d.is-zero then Rational(0, 1)
  else
    val g = gcd(n, d)
    val s = if d < 0 then -1 else 1
    Rational(s * (n / g), s * (d / g))

// The exact value of a finite float (non-finite values give zero).
pub fun float64/rational( f : float64 ) : rational
  if !f.is-finite then Rational(0, 1)
  else
    val (m, e) = f.decode
    if e >= 0 then Rational(m * (2 ^ e), 1) else rational(m, 2 ^ (0 - e))

// The numerator (with the sign of the number).
pub fun numerator( r : rational ) : int
  r.num

// The denominator (always positive).
pub fun denominator( r : rational ) : int
  r.den

pub val zero : rational = Rational(0, 1)
pub val one : rational = Rational(1, 1)

pub fun (+)( x : rational, y : rational ) : rational
  if x.den == y.den then rational(x.num + y.num, x.den)
  else rational(x.num * y.den + y.num * x.den, x.den * y.den)

pub fun (-)( x : rational, y : rational ) : rational
  x + ~y

pub fun (~)( x : rational ) : rational
  Rational(0 - x.num, x.den)

pub fun (*)( x : rational, y : rational ) : rational
  rational(x.num * y.num, x.den * y.den)

// Division; dividing by zero gives zero (as for `:int`).
pub fun (/)( x : rational, y : rational ) : rational
  rational(x.num * y.den, x.den * y.num)

// The reciprocal `1/x` (zero for zero).
pub fun recip( x : rational ) : rational
  rational(x.den, x.num)

// `x` to the power `n` (also for negative `n`).
pub fun (^)( x : rational, n : int ) : rational
  if n >= 0 then Rational(x.num ^ n, x.den ^ n)
  else x.recip ^ pretend-decreasing(0 - n)

pub fun abs( x : rational ) : rational
  Rational(x.num.abs, x.den)

// -1, 0 or 1.
pub fun sign( x : rational ) : int
  if x.num > 0 then 1 elif x.num < 0 then -1 else 0

pub fun is-zero( x : rational ) : bool
  x.num.is-zero

pub fun is-integer( x : rational ) : bool
  x.den == 1

pub fun cmp( x : rational, y : rational ) : order
  cmp(x.num * y.den, y.num * x.den)

pub fun (==)( x : rational, y : rational ) : bool
  x.num == y.num && x.den == y.den

pub fun (!=)( x : rational, y : rational ) : bool
  !(x == y)

pub fun (<)( x : rational, y : rational ) : bool
  cmp(x, y) == Lt

pub fun (<=)( x : rational, y : rational ) : bool
  cmp(x, y) != Gt

pub fun (>)( x : rational, y : rational ) : bool
  cmp(x, y) == Gt

pub fun (>=)( x : rational, y : rational ) : bool
  cmp(x, y) != Lt

pub fun min( x : rational, y : rational ) : rational
  if x <= y then x else y

pub fun max( x : rational, y : rational ) : rational
  if x >= y then x else y

// The largest integer at most `x`.
pub fun floor( x : rational ) : int
  x.num / x.den   // Euclidean division: the floor, since `den > 0`

// The smallest integer at least `x`.
pub fun ceiling( x : rational ) : int
  0 - ((0 - x.num) / x.den)

// `x` without its fraction (rounded toward zero).
pub fun truncate( x : rational ) : int
  if x.num >= 0 then x.floor else x.ceiling

// The nearest integer; halves are rounded to the even neighbour.
pub fun round( x : rational ) : int
  val fl = x.floor
  val frac = x - fl.rational
  match cmp(frac, rational(1, 2))
    Lt -> fl
    Gt -> fl + 1
    Eq -> if fl.is-even then fl else fl + 1

// The fractional part, `x - x.floor` (from 0 up to, not including, 1).
pub fun fraction( x : rational ) : rational
  x - x.floor.rational

// The nearest float.
pub fun float64( x : rational ) : float64
  // Scale so the quotient has 55 or 56 bits and make it odd when the division
  // was inexact ("round to odd"): the one rounding to 53 bits in the (exact
  // range) int conversion is then correct, and `ldexp` scales exactly.
  val n = x.num.abs
  val shift = 55 + x.den.count-digits2 - n.count-digits2
  val (scaled-n, scaled-d) = if shift >= 0 then (n * (2 ^ shift), x.den) else (n, x.den * (2 ^ (0 - shift)))
  val q = scaled-n / scaled-d
  val q1 = if q * scaled-d != scaled-n && q.is-even then q + 1 else q
  val mag = ldexp(q1.float64, 0 - shift)
  if x.num < 0 then 0.0 - mag else mag

// The number of binary digits of a non-negative integer.
fun count-digits2( i : int ) : int
  if i <= 0 then 0 else 1 + count-digits2(pretend-decreasing(i / 2))

// Show as `num/den`, or just `num` for an integer.
pub fun show( x : rational ) : string
  if x.den == 1 then x.num.show else x.num.show ++ "/" ++ x.den.show

// Show as a decimal number with `digits` digits after the point (rounded
// to the nearest, halves away from zero).
pub fun show-decimal( x : rational, digits : int = 10 ) : string
  val d = max(0, digits)
  val scale = 10 ^ d
  val scaled = (x.abs * scale.rational + rational(1, 2)).floor
  val sign = if x.num < 0 && !scaled.is-zero then "-" else ""
  val ip = (scaled / scale).show
  if d == 0 then sign ++ ip
  else sign ++ ip ++ "." ++ (scaled % scale).show.pad-left(d, '0')

// Parse `n`, `n/d` or a decimal like `-1.25` (with optional spaces around `/`).
pub fun parse-rational( s : string ) : maybe<rational>
  val t = s.trim
  match t.find("/")
    Just(sl) ->
      match (sl.before.string.trim.parse-int, sl.after.string.trim.parse-int)
        (Just(n), Just(d)) | !d.is-zero -> Just(rational(n, d))
        _ -> Nothing
    Nothing -> match t.find(".")
      Nothing -> t.parse-int.map(fn(i) rational(i))
      Just(sl) ->
        val ip = sl.before.string
        val fp = sl.after.string
        if fp.is-empty || !fp.list.all(is-digit) then Nothing
        else
          val neg = ip.starts-with("-").is-just
          match (if ip == "-" || ip.is-empty then Just(0) else ip.parse-int)
            Just(i) ->
              val f = rational(fp.parse-int.default(0), 10 ^ fp.count)
              val mag = i.abs.rational + f
              Just(if neg then ~mag else mag)
            Nothing -> Nothing

// The sum of a list of rationals.
pub fun sum( xs : list<rational> ) : rational
  xs.foldl(zero, (+))
