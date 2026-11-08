/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Complex numbers over `:float64`.

   ```
   import std/num/complex

   fun main()
     val z = complex(3.0, 4.0)
     println(z.abs)                        // 5.0
     println((z * z.conj).show)            // 25.0+0.0i
     println(exp(complex(0.0, pi)).show(3)) // -1.000+0.000i
     println(sqrt(complex(-4.0)).show)     // 0.0+2.0i
   ```
*/
module std/num/complex

import std/num/float64
import std/core/undiv

// A complex number `re + im*i`.
pub value struct complex
  re : float64
  im : float64

// The complex number `re + im*i`.
pub fun complex( re : float64, im : float64 = 0.0 ) : complex
  Complex(re, im)

// The imaginary unit.
pub val i : complex = Complex(0.0, 1.0)

pub val zero : complex = Complex(0.0, 0.0)
pub val one : complex = Complex(1.0, 0.0)

// The complex number with magnitude `r` and angle `theta` (in radians).
pub fun polar( r : float64, theta : float64 ) : complex
  Complex(r * cos(theta), r * sin(theta))

pub fun (+)( x : complex, y : complex ) : complex
  Complex(x.re + y.re, x.im + y.im)

pub fun (-)( x : complex, y : complex ) : complex
  Complex(x.re - y.re, x.im - y.im)

pub fun (~)( x : complex ) : complex
  Complex(0.0 - x.re, 0.0 - x.im)

pub fun (*)( x : complex, y : complex ) : complex
  Complex(x.re * y.re - x.im * y.im, x.re * y.im + x.im * y.re)

// Division (Smith's algorithm, which avoids needless overflow).
pub fun (/)( x : complex, y : complex ) : complex
  if y.re.abs >= y.im.abs then
    val r = y.im / y.re
    val d = y.re + y.im * r
    Complex((x.re + x.im * r) / d, (x.im - x.re * r) / d)
  else
    val r = y.re / y.im
    val d = y.re * r + y.im
    Complex((x.re * r + x.im) / d, (x.im * r - x.re) / d)

// Multiply by a real number.
pub fun scale( x : complex, f : float64 ) : complex
  Complex(x.re * f, x.im * f)

pub fun (==)( x : complex, y : complex ) : bool
  x.re == y.re && x.im == y.im

pub fun (!=)( x : complex, y : complex ) : bool
  !(x == y)

// The complex conjugate `re - im*i`.
pub fun conj( x : complex ) : complex
  Complex(x.re, 0.0 - x.im)

// The magnitude (modulus) `|x|`.
pub fun abs( x : complex ) : float64
  hypot(x.re, x.im)

// The squared magnitude `|x|^2`.
pub fun norm( x : complex ) : float64
  x.re * x.re + x.im * x.im

// The angle (argument) in radians, from -pi to pi.
pub fun arg( x : complex ) : float64
  atan2(x.im, x.re)

// The reciprocal `1/x`.
pub fun recip( x : complex ) : complex
  one / x

// `e^x`.
pub fun exp( x : complex ) : complex
  polar(float64/exp(x.re), x.im)

// The natural logarithm (principal value).
pub fun ln( x : complex ) : complex
  Complex(float64/ln(x.abs), x.arg)

// The principal square root.
pub fun sqrt( x : complex ) : complex
  if x.re == 0.0 && x.im == 0.0 then zero
  else
    val r = x.abs
    val a = float64/sqrt((r + x.re.abs) / 2.0)
    if x.re >= 0.0 then Complex(a, x.im / (2.0 * a))
    else Complex(x.im.abs / (2.0 * a), if x.im < 0.0 || x.im.is-negzero then 0.0 - a else a)

// `x` to the power `y` (principal value; `0^y` is 0, and `x^0` is 1).
pub fun pow( x : complex, y : complex ) : complex
  if y.re == 0.0 && y.im == 0.0 then one
  elif x.re == 0.0 && x.im == 0.0 then zero
  else exp(y * ln(x))

// `x` to an integer power (by repeated squaring, exact for small integers).
pub fun (^)( x : complex, n : int ) : complex
  if n < 0 then (one / x) ^ pretend-decreasing(0 - n)
  elif n == 0 then one
  else
    val h = x ^ pretend-decreasing(n / 2)
    if n.is-even then h * h else h * h * x

pub fun sin( x : complex ) : complex
  Complex(float64/sin(x.re) * cosh(x.im), float64/cos(x.re) * sinh(x.im))

pub fun cos( x : complex ) : complex
  Complex(float64/cos(x.re) * cosh(x.im), 0.0 - float64/sin(x.re) * sinh(x.im))

pub fun tan( x : complex ) : complex
  sin(x) / cos(x)

// Show as `re+imi`, like `1.5-2.0i`, with an optional number of digits after the point.
pub fun show( x : complex, digits : int = -1 ) : string
  fun num( f : float64 ) : string
    if digits >= 0 then f.show-fixed(digits)
    elif f == f.truncate && f.abs < 1.0e15 then f.int.show ++ ".0"
    else shortest-show(f, 1)
  num(x.re) ++ (if x.im < 0.0 || (x.im == 0.0 && x.im.is-negzero) then "-" else "+") ++ num(x.im.abs) ++ "i"

// the shortest representation that parses back to exactly the same number
fun shortest-show( f : float64, prec : int ) : string
  val s = f.show(0 - prec)
  if prec >= 17 || parse-float64(s) == Just(f) then s
  else shortest-show(f, pretend-decreasing(prec + 1))
