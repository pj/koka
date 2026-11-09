/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* ASN.1 values in the DER encoding (ITU-T X.690), as used by X.509
   certificates, OCSP and PKCS formats.

   ```
   import std/data/der

   fun main()
     val v = Der-seq([Der-oid("1.2.840.113549.1.1.11"), Der-null])
     val b = v.encode
     println(b.decode == v)   // True
   ```

   `decode` reads exactly one value. Signatures cover the exact encoding of
   a part of a structure; `elements` splits a constructed value into the
   encodings of its parts, so they can be checked as they were received.
*/
module std/data/der

import std/core/undiv
import std/text/encoding

// An ASN.1 value.
pub type der
  Der-bool( value : bool )
  Der-int( value : int )                     // INTEGER
  Der-enum( value : int )                    // ENUMERATED
  Der-bits( bits : bytes, unused : int )     // BIT STRING (`unused` bits at the end, 0-7)
  Der-octets( value : bytes )                // OCTET STRING
  Der-null
  Der-oid( oid : string )                    // OBJECT IDENTIFIER, dotted ("2.5.4.3")
  Der-string( tag : int, text : string )     // UTF8String (12), PrintableString (19), IA5String (22), ...
  Der-time( tag : int, text : string )       // UTCTime (23) or GeneralizedTime (24), as written
  Der-seq( items : list<der> )               // SEQUENCE
  Der-set( items : list<der> )               // SET
  // A context-specific, application or private tag (`cls` 2, 1 or 3) with its
  // content still encoded: `explicit` and `implicit` give the content.
  Der-tagged( cls : int, number : int, constructed : bool, content : bytes )
  // Any other universal type, with its content.
  Der-other( tag : int, constructed : bool, content : bytes )

pub fun der/(==)( a : der, b : der ) : div bool
  a.encode == b.encode

fun bytes/(==)( a : bytes, b : bytes ) : bool
  a.length == b.length && list(0, a.length - 1).all(fn(i) a.byte(i) == b.byte(i))

fun byte( b : bytes, i : int ) : int
  b.unsafe-index(i.ssize_t).int

pub fun der/show( d : der ) : div string
  match d
    Der-bool(b) -> b.show
    Der-int(i) -> i.show
    Der-enum(i) -> "enum " ++ i.show
    Der-bits(b, u) -> "bits(" ++ b.length.show ++ " bytes" ++ (if u > 0 then ", " ++ u.show ++ " unused" else "") ++ ")"
    Der-octets(b) -> "octets(" ++ b.length.show ++ " bytes)"
    Der-null -> "null"
    Der-oid(o) -> o
    Der-string(_, s) -> s.show
    Der-time(_, s) -> "time " ++ s
    Der-seq(xs) -> "seq[" ++ xs.map(show).join(", ") ++ "]"
    Der-set(xs) -> "set[" ++ xs.map(show).join(", ") ++ "]"
    Der-tagged(cls, n, c, b) -> (if cls == 2 then "[" ++ n.show ++ "]" else "tag " ++ cls.show ++ ":" ++ n.show) ++ (if c then "{" ++ b.length.show ++ " bytes}" else "(" ++ b.length.show ++ " bytes)")
    Der-other(t, _, b) -> "type " ++ t.show ++ "(" ++ b.length.show ++ " bytes)"

// ----------------------------------------------------------------------------
// Decoding
// ----------------------------------------------------------------------------

// Read the header at `pos`: (class, constructed, tag number, content start, content length).
fun header( b : bytes, pos : int ) : exn (int, bool, int, int, int)
  val n = b.length
  if pos >= n then throw("der: unexpected end of the data")
  val first = b.byte(pos)
  val cls = first / 64
  val constructed = (first / 32) % 2 == 1
  // the tag number, possibly in several bytes
  fun long-tag( i : int, acc : int ) : exn (int, int)
    if i >= n then throw("der: unexpected end of the data")
    val x = b.byte(i)
    val acc' = acc * 128 + x % 128
    if x >= 128 then long-tag(pretend-decreasing(i + 1), acc') else (acc', i + 1)
  val (tag, p1) = if first % 32 == 31 then long-tag(pos + 1, 0) else (first % 32, pos + 1)
  if p1 >= n then throw("der: unexpected end of the data")
  val l0 = b.byte(p1)
  val (len, p2) = if l0 < 128 then (l0, p1 + 1)
    elif l0 == 128 then throw("der: indefinite lengths are not allowed")
    else
      val k = l0 - 128
      if k > 8 || p1 + 1 + k > n then throw("der: invalid length")
      (list(0, k - 1).foldl(0, fn(acc, i) acc * 256 + b.byte(p1 + 1 + i)), p1 + 1 + k)
  if p2 + len > n then throw("der: the value is longer than the data")
  (cls, constructed, tag, p2, len)

// Decode one value (the whole input).
pub fun decode( b : bytes ) : exn der
  pretend-no-div
    val (d, next) = decode-at(b, 0)
    if next != b.length then throw("der: data after the value")
    d

// Decode the values one after another (the whole input).
pub fun decode-all( b : bytes ) : exn list<der>
  pretend-no-div { parse-all(b) }

fun parse-all( b : bytes ) : <div,exn> list<der>
  fun go( pos : int ) : <div,exn> list<der>
    if pos >= b.length then Nil
    else
      val (d, next) = decode-at(b, pos)
      Cons(d, go(next))
  go(0)

// The encodings of values one after another (the whole input).
pub fun split( b : bytes ) : exn list<bytes>
  fun go( pos : int ) : exn list<bytes>
    if pos >= b.length then Nil
    else
      val (_, _, _, s, l) = header(b, pos)
      Cons(b.subbytes(pos, s + l - pos), go(pretend-decreasing(s + l)))
  go(0)

// The encodings of the parts of a constructed value (such as a SEQUENCE).
pub fun elements( b : bytes ) : exn list<bytes>
  val (_, constructed, _, start, len) = header(b, 0)
  if !constructed then throw("der: not a constructed value")
  fun go( pos : int ) : exn list<bytes>
    if pos >= start + len then Nil
    else
      val (_, _, _, s, l) = header(b, pos)
      Cons(b.subbytes(pos, s + l - pos), go(pretend-decreasing(s + l)))
  go(start)

fun decode-at( b : bytes, pos : int ) : <div,exn> (der, int)
  val (cls, constructed, tag, start, len) = header(b, pos)
  val content = b.subbytes(start, len)
  val next = start + len
  val d = if cls != 0 then Der-tagged(cls, tag, constructed, content)
    else match tag
      1  -> if len != 1 then throw("der: invalid BOOLEAN") else Der-bool(content.byte(0) != 0)
      2  -> Der-int(content.signed)
      10 -> Der-enum(content.signed)
      3  -> if len < 1 || content.byte(0) > 7 then throw("der: invalid BIT STRING")
            else Der-bits(content.subbytes(1), content.byte(0))
      4  -> Der-octets(content)
      5  -> Der-null
      6  -> Der-oid(content.oid)
      16 -> Der-seq(parse-all(content))
      17 -> Der-set(parse-all(content))
      12 -> Der-string(tag, content.string)
      18 -> Der-string(tag, content.string)
      19 -> Der-string(tag, content.string)
      20 -> Der-string(tag, content.string)
      22 -> Der-string(tag, content.string)
      26 -> Der-string(tag, content.string)
      23 -> Der-time(tag, content.string)
      24 -> Der-time(tag, content.string)
      _  -> Der-other(tag, constructed, content)
  (d, next)

// A two's complement integer.
fun signed( b : bytes ) : exn int
  if b.length == 0 then throw("der: empty INTEGER")
  val u = b.unsigned
  if b.byte(0) >= 128 then u - pow(256, b.length) else u

// An unsigned big-endian integer.
pub fun unsigned( b : bytes ) : int
  list(0, b.length - 1).foldl(0, fn(acc, i) acc * 256 + b.byte(i))

fun oid( b : bytes ) : exn string
  // base-128 numbers; the first one holds two components
  fun numbers( i : int, acc : int ) : exn list<int>
    if i >= b.length then (if acc != 0 then throw("der: invalid OBJECT IDENTIFIER") else Nil)
    else
      val x = b.byte(i)
      val acc' = acc * 128 + x % 128
      if x >= 128 then numbers(pretend-decreasing(i + 1), acc')
      else Cons(acc', numbers(pretend-decreasing(i + 1), 0))
  match numbers(0, 0)
    Cons(first, rest) ->
      val (a, b') = if first < 40 then (0, first) elif first < 80 then (1, first - 40) else (2, first - 80)
      Cons(a, Cons(b', rest)).map(show).join(".")
    Nil -> throw("der: empty OBJECT IDENTIFIER")

// The value inside an explicitly tagged value (`[n] EXPLICIT`).
pub fun explicit( d : der ) : exn der
  match d
    Der-tagged(_, _, True, content) -> decode(content)
    _ -> throw("der: not an explicitly tagged value")

// The content of an implicitly tagged value, decoded as the universal type
// `tag` (for example 4 for `[n] IMPLICIT OCTET STRING`, 16 for a SEQUENCE).
pub fun implicit( d : der, tag : int ) : exn der
  match d
    Der-tagged(_, _, constructed, content) -> decode(header-bytes(0, if tag == 16 || tag == 17 then True else constructed, tag, content.length) ++ content)
    _ -> throw("der: not a tagged value")

// ----------------------------------------------------------------------------
// Encoding
// ----------------------------------------------------------------------------

fun header-bytes( cls : int, constructed : bool, tag : int, len : int ) : bytes
  val first = cls * 64 + (if constructed then 32 else 0)
  val id = if tag < 31 then [first + tag] else Cons(first + 31, base128(tag))
  val lens = if len < 128 then [len] else
    val bs = big-endian(len)
    Cons(128 + bs.length, bs)
  (id ++ lens).byte-list

fun byte-list( xs : list<int> ) : bytes
  vector(xs).bytes

fun big-endian( n : int ) : list<int>
  fun go( m : int, acc : list<int> ) : list<int>
    if m == 0 then acc else go(pretend-decreasing(m / 256), Cons(m % 256, acc))
  if n == 0 then [0] else go(n, [])

fun base128( n : int ) : list<int>
  fun go( m : int, acc : list<int> ) : list<int>
    if m == 0 then acc else go(pretend-decreasing(m / 128), Cons(m % 128 + 128, acc))
  match go(n / 128, [])
    acc -> acc ++ [n % 128]

// The two's complement encoding of an integer, in as few bytes as possible.
fun int-bytes( i : int ) : list<int>
  if i >= 0 then
    val bs = big-endian(i)
    if bs.head.default(0) >= 128 then Cons(0, bs) else bs
  else
    // the smallest k with -256^k/2 <= i
    fun width( k : int ) : int
      if i >= 0 - pow(256, k) / 2 then k else width(pretend-decreasing(k + 1))
    val k = width(1)
    val u = pow(256, k) + i
    val bs = big-endian(u)
    list(1, k - bs.length).map(fn(_) 0) ++ bs

fun oid-bytes( oid : string ) : exn list<int>
  val ns = oid.split(".").map(fn(s) match s.parse-int { Just(n) | n >= 0 -> n; _ -> throw("der: invalid OBJECT IDENTIFIER " ++ oid.show) })
  match ns
    Cons(a, Cons(b, rest)) | a <= 2 -> Cons(a * 40 + b, rest).flatmap(base128)
    _ -> throw("der: invalid OBJECT IDENTIFIER " ++ oid.show)

fun primitive( tag : int, content : bytes ) : bytes
  header-bytes(0, False, tag, content.length) ++ content

fun constructed( tag : int, content : bytes ) : bytes
  header-bytes(0, True, tag, content.length) ++ content

// The DER encoding of a value.
pub fun encode( d : der ) : div bytes
  match d
    Der-bool(b) -> primitive(1, [if b then 255 else 0].byte-list)
    Der-int(i) -> primitive(2, int-bytes(i).byte-list)
    Der-enum(i) -> primitive(10, int-bytes(i).byte-list)
    Der-bits(b, u) -> primitive(3, [u].byte-list ++ b)
    Der-octets(b) -> primitive(4, b)
    Der-null -> primitive(5, bytes/empty)
    Der-oid(o) -> primitive(6, (match try({ oid-bytes(o) }) { Ok(xs) -> xs; Error(_) -> [] }).byte-list)
    Der-string(tag, s) -> primitive(tag, s.bytes)
    Der-time(tag, s) -> primitive(tag, s.bytes)
    Der-seq(xs) -> constructed(16, xs.map(encode).join-bytes)
    Der-set(xs) -> constructed(17, xs.map(encode).sort-bytes.join-bytes)   // DER sorts SET OF
    Der-tagged(cls, n, c, content) -> header-bytes(cls, c, n, content.length) ++ content
    Der-other(tag, c, content) -> header-bytes(0, c, tag, content.length) ++ content

fun join-bytes( xs : list<bytes> ) : bytes
  xs.foldl(bytes/empty, fn(acc, x) acc ++ x)

fun sort-bytes( xs : list<bytes> ) : list<bytes>
  xs.sort(?cmp = fn(a, b) compare-bytes(a, b, 0))

fun compare-bytes( a : bytes, b : bytes, i : int ) : order
  if i >= a.length || i >= b.length then cmp(a.length, b.length)
  else match cmp(a.byte(i), b.byte(i))
    Eq -> compare-bytes(a, b, pretend-decreasing(i + 1))
    o -> o

// `[n] EXPLICIT` around a value (context-specific).
pub fun tag-explicit( n : int, d : der ) : div der
  Der-tagged(2, n, True, d.encode)

// `[n] IMPLICIT`: the value's content with a context-specific tag.
pub fun tag-implicit( n : int, d : der ) : <div,exn> der
  val b = d.encode
  val (_, constructed, _, start, len) = header(b, 0)
  Der-tagged(2, n, constructed, b.subbytes(start, len))

// ----------------------------------------------------------------------------
// PEM
// ----------------------------------------------------------------------------

// The DER contents of the PEM blocks with the given label (such as
// `"CERTIFICATE"`) in a text, in order.
pub fun pem-decode( text : string, label : string = "CERTIFICATE" ) : exn list<bytes>
  val begin = "-----BEGIN " ++ label ++ "-----"
  val end = "-----END " ++ label ++ "-----"
  fun go( lines : list<string>, inside : maybe<list<string>> ) : exn list<bytes>
    match lines
      Nil -> Nil
      Cons(l, rest) ->
        val t = l.trim
        match inside
          Nothing -> if t == begin then go(rest, Just([])) else go(rest, Nothing)
          Just(acc) ->
            if t == end then
              match base64-decode(acc.reverse.join)
                Just(b) -> Cons(b, go(rest, Nothing))
                Nothing -> throw("pem: invalid base64 in a " ++ label ++ " block")
            else go(rest, Just(Cons(t, acc)))
  go(text.lines, Nothing)

// A PEM block with the given label.
pub fun pem-encode( der : bytes, label : string = "CERTIFICATE" ) : string
  val b64 = base64-encode(der)
  fun chunks( s : string ) : list<string>
    if s.count <= 64 then [s] else Cons(s.first(64).string, chunks(pretend-decreasing(s.first(64).after.string)))
  "-----BEGIN " ++ label ++ "-----\n" ++ chunks(b64).join("\n") ++ "\n-----END " ++ label ++ "-----\n"
