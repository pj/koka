/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* HPACK: header compression for HTTP/2 ([RFC 7541](https://www.rfc-editor.org/rfc/rfc7541)).

   ```
   val block = hpack-encode([(":method", "GET"), (":path", "/"), ("user-agent", "koka")])
   val (headers, decoder') = hpack-decoder().decode(block)
   ```

   The decoder supports the full format, including the dynamic table and
   Huffman coded strings. The encoder does not use the dynamic table (so it
   needs no state); it uses the static table and Huffman coding where that is
   shorter.
*/
module std/net/hpack

import std/core/undiv

// A header list: names are lower case in HTTP/2.
pub alias header-list = list<(string, string)>

// ----------------------------------------------------------------------------
// Tables (RFC 7541, appendices A and B)
// ----------------------------------------------------------------------------

// The static table; entry `i` (1-based) is at position `i - 1`.
val static-table : vector<(string, string)> = [
  (":authority", ""),
  (":method", "GET"),
  (":method", "POST"),
  (":path", "/"),
  (":path", "/index.html"),
  (":scheme", "http"),
  (":scheme", "https"),
  (":status", "200"),
  (":status", "204"),
  (":status", "206"),
  (":status", "304"),
  (":status", "400"),
  (":status", "404"),
  (":status", "500"),
  ("accept-charset", ""),
  ("accept-encoding", "gzip, deflate"),
  ("accept-language", ""),
  ("accept-ranges", ""),
  ("accept", ""),
  ("access-control-allow-origin", ""),
  ("age", ""),
  ("allow", ""),
  ("authorization", ""),
  ("cache-control", ""),
  ("content-disposition", ""),
  ("content-encoding", ""),
  ("content-language", ""),
  ("content-length", ""),
  ("content-location", ""),
  ("content-range", ""),
  ("content-type", ""),
  ("cookie", ""),
  ("date", ""),
  ("etag", ""),
  ("expect", ""),
  ("expires", ""),
  ("from", ""),
  ("host", ""),
  ("if-match", ""),
  ("if-modified-since", ""),
  ("if-none-match", ""),
  ("if-range", ""),
  ("if-unmodified-since", ""),
  ("last-modified", ""),
  ("link", ""),
  ("location", ""),
  ("max-forwards", ""),
  ("proxy-authenticate", ""),
  ("proxy-authorization", ""),
  ("range", ""),
  ("referer", ""),
  ("refresh", ""),
  ("retry-after", ""),
  ("server", ""),
  ("set-cookie", ""),
  ("strict-transport-security", ""),
  ("transfer-encoding", ""),
  ("user-agent", ""),
  ("vary", ""),
  ("via", ""),
  ("www-authenticate", "")
].vector

// The Huffman code of each symbol (0..255, and 256 for end-of-string): `(code, length in bits)`.
val huffman-codes : vector<(int, int)> = [
  (0x1ff8,13), (0x7fffd8,23), (0xfffffe2,28), (0xfffffe3,28), (0xfffffe4,28), (0xfffffe5,28), (0xfffffe6,28), (0xfffffe7,28),
  (0xfffffe8,28), (0xffffea,24), (0x3ffffffc,30), (0xfffffe9,28), (0xfffffea,28), (0x3ffffffd,30), (0xfffffeb,28), (0xfffffec,28),
  (0xfffffed,28), (0xfffffee,28), (0xfffffef,28), (0xffffff0,28), (0xffffff1,28), (0xffffff2,28), (0x3ffffffe,30), (0xffffff3,28),
  (0xffffff4,28), (0xffffff5,28), (0xffffff6,28), (0xffffff7,28), (0xffffff8,28), (0xffffff9,28), (0xffffffa,28), (0xffffffb,28),
  (0x14,6), (0x3f8,10), (0x3f9,10), (0xffa,12), (0x1ff9,13), (0x15,6), (0xf8,8), (0x7fa,11),
  (0x3fa,10), (0x3fb,10), (0xf9,8), (0x7fb,11), (0xfa,8), (0x16,6), (0x17,6), (0x18,6),
  (0x0,5), (0x1,5), (0x2,5), (0x19,6), (0x1a,6), (0x1b,6), (0x1c,6), (0x1d,6),
  (0x1e,6), (0x1f,6), (0x5c,7), (0xfb,8), (0x7ffc,15), (0x20,6), (0xffb,12), (0x3fc,10),
  (0x1ffa,13), (0x21,6), (0x5d,7), (0x5e,7), (0x5f,7), (0x60,7), (0x61,7), (0x62,7),
  (0x63,7), (0x64,7), (0x65,7), (0x66,7), (0x67,7), (0x68,7), (0x69,7), (0x6a,7),
  (0x6b,7), (0x6c,7), (0x6d,7), (0x6e,7), (0x6f,7), (0x70,7), (0x71,7), (0x72,7),
  (0xfc,8), (0x73,7), (0xfd,8), (0x1ffb,13), (0x7fff0,19), (0x1ffc,13), (0x3ffc,14), (0x22,6),
  (0x7ffd,15), (0x3,5), (0x23,6), (0x4,5), (0x24,6), (0x5,5), (0x25,6), (0x26,6),
  (0x27,6), (0x6,5), (0x74,7), (0x75,7), (0x28,6), (0x29,6), (0x2a,6), (0x7,5),
  (0x2b,6), (0x76,7), (0x2c,6), (0x8,5), (0x9,5), (0x2d,6), (0x77,7), (0x78,7),
  (0x79,7), (0x7a,7), (0x7b,7), (0x7ffe,15), (0x7fc,11), (0x3ffd,14), (0x1ffd,13), (0xffffffc,28),
  (0xfffe6,20), (0x3fffd2,22), (0xfffe7,20), (0xfffe8,20), (0x3fffd3,22), (0x3fffd4,22), (0x3fffd5,22), (0x7fffd9,23),
  (0x3fffd6,22), (0x7fffda,23), (0x7fffdb,23), (0x7fffdc,23), (0x7fffdd,23), (0x7fffde,23), (0xffffeb,24), (0x7fffdf,23),
  (0xffffec,24), (0xffffed,24), (0x3fffd7,22), (0x7fffe0,23), (0xffffee,24), (0x7fffe1,23), (0x7fffe2,23), (0x7fffe3,23),
  (0x7fffe4,23), (0x1fffdc,21), (0x3fffd8,22), (0x7fffe5,23), (0x3fffd9,22), (0x7fffe6,23), (0x7fffe7,23), (0xffffef,24),
  (0x3fffda,22), (0x1fffdd,21), (0xfffe9,20), (0x3fffdb,22), (0x3fffdc,22), (0x7fffe8,23), (0x7fffe9,23), (0x1fffde,21),
  (0x7fffea,23), (0x3fffdd,22), (0x3fffde,22), (0xfffff0,24), (0x1fffdf,21), (0x3fffdf,22), (0x7fffeb,23), (0x7fffec,23),
  (0x1fffe0,21), (0x1fffe1,21), (0x3fffe0,22), (0x1fffe2,21), (0x7fffed,23), (0x3fffe1,22), (0x7fffee,23), (0x7fffef,23),
  (0xfffea,20), (0x3fffe2,22), (0x3fffe3,22), (0x3fffe4,22), (0x7ffff0,23), (0x3fffe5,22), (0x3fffe6,22), (0x7ffff1,23),
  (0x3ffffe0,26), (0x3ffffe1,26), (0xfffeb,20), (0x7fff1,19), (0x3fffe7,22), (0x7ffff2,23), (0x3fffe8,22), (0x1ffffec,25),
  (0x3ffffe2,26), (0x3ffffe3,26), (0x3ffffe4,26), (0x7ffffde,27), (0x7ffffdf,27), (0x3ffffe5,26), (0xfffff1,24), (0x1ffffed,25),
  (0x7fff2,19), (0x1fffe3,21), (0x3ffffe6,26), (0x7ffffe0,27), (0x7ffffe1,27), (0x3ffffe7,26), (0x7ffffe2,27), (0xfffff2,24),
  (0x1fffe4,21), (0x1fffe5,21), (0x3ffffe8,26), (0x3ffffe9,26), (0xffffffd,28), (0x7ffffe3,27), (0x7ffffe4,27), (0x7ffffe5,27),
  (0xfffec,20), (0xfffff3,24), (0xfffed,20), (0x1fffe6,21), (0x3fffe9,22), (0x1fffe7,21), (0x1fffe8,21), (0x7ffff3,23),
  (0x3fffea,22), (0x3fffeb,22), (0x1ffffee,25), (0x1ffffef,25), (0xfffff4,24), (0xfffff5,24), (0x3ffffea,26), (0x7ffff4,23),
  (0x3ffffeb,26), (0x7ffffe6,27), (0x3ffffec,26), (0x3ffffed,26), (0x7ffffe7,27), (0x7ffffe8,27), (0x7ffffe9,27), (0x7ffffea,27),
  (0x7ffffeb,27), (0xffffffe,28), (0x7ffffec,27), (0x7ffffed,27), (0x7ffffee,27), (0x7ffffef,27), (0x7fffff0,27), (0x3ffffee,26),
  (0x3fffffff,30)
].vector

// ----------------------------------------------------------------------------
// Integers and bits
// ----------------------------------------------------------------------------

fun pow2( n : int ) : int
  if n <= 0 then 1 else 2 * pow2(pretend-decreasing(n - 1))

fun byte-at( b : bytes, i : int ) : exn int
  if i < 0 || i >= b.length then throw("hpack: truncated header block") else b.unsafe-index(i.ssize_t).int

// Decode an integer with an `n`-bit prefix at `pos`; returns the value and the next position.
fun decode-int( b : bytes, pos : int, n : int ) : exn (int, int)
  val max-prefix = pow2(n) - 1
  val first = b.byte-at(pos) % pow2(n)
  if first < max-prefix then (first, pos + 1)
  else
    fun go( i : int, value : int, shift : int ) : exn (int, int)
      if shift > 28 then throw("hpack: integer too large")
      val x = b.byte-at(i)
      val value' = value + (x % 128) * pow2(shift)
      if x >= 128 then go(pretend-decreasing(i + 1), value', shift + 7) else (value', i + 1)
    go(pos + 1, max-prefix, 0)

// Encode an integer with an `n`-bit prefix; `flags` are the bits above the prefix in the first byte.
fun encode-int( value : int, n : int, flags : int ) : list<int>
  val max-prefix = pow2(n) - 1
  if value < max-prefix then [flags + value]
  else
    fun rest( v : int ) : list<int>
      if v >= 128 then Cons(128 + v % 128, rest(pretend-decreasing(v / 128))) else [v]
    Cons(flags + max-prefix, rest(value - max-prefix))

// ----------------------------------------------------------------------------
// Huffman coding
// ----------------------------------------------------------------------------

type htree
  HLeaf( sym : int )
  HNode( zero : htree, one : htree )
  HNone

fun htree/insert( t : htree, code : int, len : int, sym : int ) : htree
  if len == 0 then HLeaf(sym)
  else
    val bit = (code / pow2(len - 1)) % 2
    val (z, o) = match t
      HNode(z, o) -> (z, o)
      _ -> (HNone, HNone)
    if bit == 0 then HNode(z.insert(code, pretend-decreasing(len - 1), sym), o)
                else HNode(z, o.insert(code, pretend-decreasing(len - 1), sym))

val huffman-tree : htree =
  fun build( t : htree, codes : list<(int, int)>, sym : int ) : htree
    match codes
      Cons((code, len), rest) -> build(t.insert(code, len, sym), rest, sym + 1)
      Nil -> t
  build(HNone, huffman-codes.list, 0)

// Decode a Huffman coded string (RFC 7541 section 5.2).
pub fun huffman-decode( b : bytes ) : exn bytes
  // `pad` counts the bits since the last symbol; `ones` is whether they were all 1
  fun go( i : int, bit : int, node : htree, pad : int, ones : bool, acc : list<int> ) : exn list<int>
    if i >= b.length then
      if pad > 7 || !ones then throw("hpack: invalid Huffman padding") else acc.reverse
    else
      val x = (b.byte-at(i) / pow2(7 - bit)) % 2
      val (i', bit') = if bit == 7 then (i + 1, 0) else (i, bit + 1)
      val next = match node
        HNode(z, o) -> if x == 0 then z else o
        _ -> HNone
      match next
        HLeaf(256) -> throw("hpack: end-of-string symbol in a Huffman string")
        HLeaf(sym) -> go(pretend-decreasing(i'), bit', huffman-tree, 0, True, Cons(sym, acc))
        HNode -> go(pretend-decreasing(i'), bit', next, pad + 1, ones && x == 1, acc)
        HNone -> throw("hpack: invalid Huffman code")
  go(0, 0, huffman-tree, 0, True, []).vector.bytes

// The length of the Huffman coding of `b` in bytes.
fun huffman-length( b : bytes ) : int
  val bits = b.list.foldl(0, fn(n, x) n + huffman-codes.at(x).default((0, 0)).snd)
  (bits + 7) / 8

// Huffman code a string (RFC 7541 section 5.2).
pub fun huffman-encode( b : bytes ) : bytes
  fun go( xs : list<int>, acc : int, nbits : int, out : list<int> ) : list<int>
    if nbits >= 8 then
      val p = pow2(nbits - 8)
      go(xs, acc % p, pretend-decreasing(nbits - 8), Cons(acc / p, out))
    else match xs
      Cons(x, rest) ->
        val (code, len) = huffman-codes.at(x).default((0, 0))
        go(rest, acc * pow2(len) + code, nbits + len, out)
      Nil ->
        if nbits == 0 then out.reverse
        else
          // pad with the most significant bits of end-of-string (all ones)
          val padbits = 8 - nbits
          Cons(acc * pow2(padbits) + pow2(padbits) - 1, out).reverse
  go(b.list, 0, 0, []).vector.bytes

// ----------------------------------------------------------------------------
// Decoding
// ----------------------------------------------------------------------------

// The state of a decoder: its dynamic table. Use a decoder for all header
// blocks of one connection, in order.
abstract struct hpack-decoder
  table : list<(string, string)>   // newest first
  size : int                       // the size of the entries (name + value + 32 each)
  max-size : int                   // the current maximum size
  limit : int                      // the maximum size the peer may set (our `SETTINGS_HEADER_TABLE_SIZE`)

// A new decoder whose dynamic table may grow to `max-table-size` bytes.
pub fun hpack-decoder( max-table-size : int = 4096 ) : hpack-decoder
  Hpack-decoder([], 0, max-table-size, max-table-size)

// The current size of the dynamic table (RFC 7541 section 4.1).
pub fun table-size( d : hpack-decoder ) : int
  d.size

fun entry-size( (name, value) : (string, string) ) : int
  name.bytes.length + value.bytes.length + 32

fun evict( d : hpack-decoder ) : hpack-decoder
  if d.size <= d.max-size then d
  else match d.table.reverse
    Cons(oldest, rest) -> evict(pretend-decreasing(Hpack-decoder(rest.reverse, d.size - oldest.entry-size, d.max-size, d.limit)))
    Nil -> d

fun add( d : hpack-decoder, entry : (string, string) ) : hpack-decoder
  evict(Hpack-decoder(Cons(entry, d.table), d.size + entry.entry-size, d.max-size, d.limit))

fun lookup( d : hpack-decoder, index : int ) : exn (string, string)
  if index <= 0 then throw("hpack: invalid index 0")
  elif index <= static-table.length then static-table.at(index - 1).default(("", ""))
  else match d.table.drop(index - static-table.length - 1)
    Cons(entry, _) -> entry
    Nil -> throw("hpack: invalid index " ++ index.show)

fun decode-string( b : bytes, pos : int ) : exn (string, int)
  val huffman = b.byte-at(pos) >= 128
  val (len, start) = decode-int(b, pos, 7)
  if start + len > b.length then throw("hpack: truncated string")
  val octets = b.subbytes(start, len)
  ((if huffman then huffman-decode(octets) else octets).string, start + len)

// Decode a header block; returns the headers and the updated decoder.
pub fun decode( d : hpack-decoder, block : bytes ) : exn (header-list, hpack-decoder)
  fun literal( dec : hpack-decoder, pos : int, n : int ) : exn ((string, string), int)
    val (index, next) = decode-int(block, pos, n)
    val (name, after-name) = if index == 0 then decode-string(block, next) else (dec.lookup(index).fst, next)
    val (value, after-value) = decode-string(block, after-name)
    ((name, value), after-value)
  fun go( dec : hpack-decoder, pos : int, acc : header-list ) : exn (header-list, hpack-decoder)
    if pos >= block.length then (acc.reverse, dec)
    else
      val x = block.byte-at(pos)
      if x >= 128 then             // indexed header field
        val (index, next) = decode-int(block, pos, 7)
        go(dec, pretend-decreasing(next), Cons(dec.lookup(index), acc))
      elif x >= 64 then            // literal with incremental indexing
        val (entry, next) = literal(dec, pos, 6)
        go(dec.add(entry), pretend-decreasing(next), Cons(entry, acc))
      elif x >= 32 then            // dynamic table size update
        val (new-size, next) = decode-int(block, pos, 5)
        if new-size > dec.limit then throw("hpack: table size update above the limit")
        go(evict(Hpack-decoder(dec.table, dec.size, new-size, dec.limit)), pretend-decreasing(next), acc)
      else                         // literal without indexing, or never indexed
        val (entry, next) = literal(dec, pos, 4)
        go(dec, pretend-decreasing(next), Cons(entry, acc))
  go(d, 0, [])

// ----------------------------------------------------------------------------
// Encoding
// ----------------------------------------------------------------------------

// The static table index of `(name, value)` and of `name` alone; 0 if not present.
fun static-index( name : string, value : string ) : (int, int)
  fun go( entries : list<(string, string)>, i : int, both : int, only : int ) : (int, int)
    match entries
      Cons((n, v), rest) ->
        if n != name then go(rest, i + 1, both, only)
        elif v == value && both == 0 then go(rest, i + 1, i, only)
        elif only == 0 then go(rest, i + 1, both, i)
        else go(rest, i + 1, both, only)
      Nil -> (both, only)
  go(static-table.list, 1, 0, 0)

fun encode-string( s : string, huffman : bool ) : list<int>
  val octets = s.bytes
  if huffman && huffman-length(octets) < octets.length then
    val h = huffman-encode(octets)
    encode-int(h.length, 7, 128) ++ h.list
  else encode-int(octets.length, 7, 0) ++ octets.list

// Encode a header list into a header block. Header names should be lower
// case. The dynamic table is not used, so blocks can be decoded in any
// order by any decoder.
pub fun hpack-encode( headers : header-list, huffman : bool = True ) : bytes
  headers.flatmap(fn((name, value))
    match static-index(name, value)
      (both, _) | both > 0 -> encode-int(both, 7, 128)
      (_, only) | only > 0 -> encode-int(only, 4, 0) ++ encode-string(value, huffman)
      _ -> [0] ++ encode-string(name, huffman) ++ encode-string(value, huffman)
  ).vector.bytes
