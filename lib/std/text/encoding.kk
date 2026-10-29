/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Binary-to-text encodings: base64, hexadecimal, and percent (URL) encoding.

   Encoders take `:bytes` (use `s.bytes` to encode a `:string` as UTF-8) and
   return a `:string`. Decoders return `Nothing` on malformed input.

   ```
   "hello".bytes.base64-encode              // "aGVsbG8="
   "aGVsbG8=".base64-decode.map(string)     // Just("hello")
   "a b&c".percent-encode                   // "a%20b%26c"
   ```
*/
module std/text/encoding

import std/core/undiv

// ----------------------------------------------------------------------------
// Base64 (RFC 4648)
// ----------------------------------------------------------------------------

fun b64-char( i : int, url-safe : bool ) : char
  if i < 26 then (i + 65).char
  elif i < 52 then (i - 26 + 97).char
  elif i < 62 then (i - 52 + 48).char
  elif i == 62 then (if url-safe then '-' else '+')
  else (if url-safe then '_' else '/')

fun b64-value( c : char ) : int
  if c >= 'A' && c <= 'Z' then c.int - 65
  elif c >= 'a' && c <= 'z' then c.int - 97 + 26
  elif c >= '0' && c <= '9' then c.int - 48 + 52
  elif c == '+' || c == '-' then 62
  elif c == '/' || c == '_' then 63
  else -1

inline fun byte-at( b : bytes, i : int ) : int
  b.unsafe-index(i.ssize_t).int

// Encode bytes as base64. Use `url-safe=True` for the URL and filename safe
// alphabet (`-` and `_` instead of `+` and `/`), and `pad=False` to omit
// trailing `=` padding.
pub fun base64-encode( b : bytes, url-safe : bool = False, pad : bool = True ) : string
  val n = b.length
  var acc := Nil
  val groups = n / 3
  for(0, groups - 1) fn(g)
    val i = 3*g
    val v = b.byte-at(i) * 65536 + b.byte-at(i+1) * 256 + b.byte-at(i+2)
    acc := Cons((v % 64).b64-char(url-safe), Cons((v / 64 % 64).b64-char(url-safe),
           Cons((v / 4096 % 64).b64-char(url-safe), Cons((v / 262144).b64-char(url-safe), acc))))
  val i = 3*groups
  val rem = n - i
  if rem == 1 then
    val v = b.byte-at(i) * 65536
    acc := Cons((v / 4096 % 64).b64-char(url-safe), Cons((v / 262144).b64-char(url-safe), acc))
    if pad then acc := Cons('=', Cons('=', acc))
  elif rem == 2 then
    val v = b.byte-at(i) * 65536 + b.byte-at(i+1) * 256
    acc := Cons((v / 64 % 64).b64-char(url-safe), Cons((v / 4096 % 64).b64-char(url-safe), Cons((v / 262144).b64-char(url-safe), acc)))
    if pad then acc := Cons('=', acc)
  acc.reverse.string

// Decode a base64 string. Both the standard and the URL-safe alphabet are
// accepted, padding is optional, and whitespace is ignored.
pub fun base64-decode( s : string ) : maybe<bytes>
  val cs = s.list.filter(fn(c) !c.is-white && c != '=')
  val vals = cs.map(b64-value)
  if vals.any(fn(v) v < 0) then return Nothing
  val n = vals.length
  if n % 4 == 1 then return Nothing
  Just(b64-groups(vals).vector.bytes)

fun b64-groups( xs : list<int> ) : list<int>
  match xs
    Cons(a, Cons(b, Cons(c, Cons(d, rest)))) ->
      val v = ((a * 64 + b) * 64 + c) * 64 + d
      Cons(v / 65536, Cons(v / 256 % 256, Cons(v % 256, b64-groups(rest))))
    Cons(a, Cons(b, Cons(c, Nil))) ->
      val v = ((a * 64 + b) * 64 + c) * 64
      [v / 65536, v / 256 % 256]
    Cons(a, Cons(b, Nil)) ->
      [(a * 64 + b) * 4096 / 65536]
    _ -> Nil

// ----------------------------------------------------------------------------
// Hexadecimal
// ----------------------------------------------------------------------------

fun hex-char( i : int, upper : bool ) : char
  if i < 10 then (i + 48).char
  elif upper then (i - 10 + 65).char
  else (i - 10 + 97).char

fun hex-value( c : char ) : int
  if c >= '0' && c <= '9' then c.int - 48
  elif c >= 'a' && c <= 'f' then c.int - 97 + 10
  elif c >= 'A' && c <= 'F' then c.int - 65 + 10
  else -1

// Encode bytes as a hexadecimal string (two digits per byte).
pub fun hex-encode( b : bytes, upper : bool = False ) : string
  var acc := Nil
  b.foreach fn(x)
    acc := Cons((x % 16).hex-char(upper), Cons((x / 16).hex-char(upper), acc))
  acc.reverse.string

// Decode a hexadecimal string (case insensitive; whitespace is ignored).
pub fun hex-decode( s : string ) : maybe<bytes>
  val vals = s.list.filter(fn(c) !c.is-white).map(hex-value)
  if vals.any(fn(v) v < 0) || vals.length.is-odd then return Nothing
  Just(hex-pairs(vals).vector.bytes)

fun hex-pairs( xs : list<int> ) : list<int>
  match xs
    Cons(hi, Cons(lo, rest)) -> Cons(hi * 16 + lo, hex-pairs(rest))
    _ -> Nil

// ----------------------------------------------------------------------------
// Percent encoding (RFC 3986)
// ----------------------------------------------------------------------------

fun is-unreserved( x : int ) : bool
  (x >= 65 && x <= 90) || (x >= 97 && x <= 122) || (x >= 48 && x <= 57) ||
  x == 45 || x == 46 || x == 95 || x == 126   // - . _ ~

// Percent-encode a string (as UTF-8). All characters except the RFC 3986
// unreserved characters (`A-Z a-z 0-9 - . _ ~`) and the characters in `safe`
// are encoded. Use `safe="/"` to encode a URL path.
pub fun percent-encode( s : string, safe : string = "" ) : string
  val safe-bytes = safe.bytes.list
  var acc := Nil
  s.bytes.foreach fn(x)
    if x.is-unreserved || safe-bytes.any(fn(y) x == y) then acc := Cons(x.char, acc)
    else acc := Cons((x % 16).hex-char(True), Cons((x / 16).hex-char(True), Cons('%', acc)))
  acc.reverse.string

// Decode a percent-encoded string. If `plus-as-space` is `True`, `+` decodes
// to a space (as in `application/x-www-form-urlencoded`).
pub fun percent-decode( s : string, plus-as-space : bool = False ) : maybe<string>
  match pct-bytes(s.bytes.list, plus-as-space)
    Just(xs) -> Just(xs.vector.bytes.string)
    Nothing -> Nothing

fun pct-bytes( xs : list<int>, plus-as-space : bool ) : maybe<list<int>>
  match xs
    Nil -> Just(Nil)
    Cons(37, Cons(h, Cons(l, rest))) ->   // '%'
      val hi = h.char.hex-value
      val lo = l.char.hex-value
      if hi < 0 || lo < 0 then Nothing
      else pct-bytes(rest, plus-as-space).map(fn(r) Cons(hi * 16 + lo, r))
    Cons(37, _) -> Nothing
    Cons(43, rest) | plus-as-space -> pct-bytes(rest, plus-as-space).map(fn(r) Cons(32, r))
    Cons(x, rest) -> pct-bytes(rest, plus-as-space).map(fn(r) Cons(x, r))
