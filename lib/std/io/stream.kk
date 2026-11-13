/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Byte streams.

   A `:byte-stream<e>` is a lazy sequence of byte chunks (a `:seq<e,bytes>`),
   read with effect `e` as they are needed. Files, standard input, sockets,
   TLS connections and child processes can all be read as streams, and the
   functions here split them into lines or records, decode UTF-8 text, and
   read protocols incrementally. Since a stream is a sequence, all of
   `std/core/seq` works on it too (`map`, `take`, `foreach`, ...).

   ```
   import std/io/stream
   import std/os/fs

   fun main()
     // count the lines of a file of any size, in constant memory
     with-file("big.log".path, Read) fn(f)
       println(f.stream.lines.length)
   ```

   A writer is just a function that takes bytes, such as `file-handle/write`,
   and `pipe` copies a stream into one:

   ```
   with-file("copy.log".path, Write) fn(out)
     with-file("big.log".path, Read) fn(inp)
       inp.stream.pipe(fn(b) out.write(b))
   ```

   Streams that are read from a handle or a socket (with `from-reader`) are
   consumed as they are read: every time a part of such a stream is forced,
   the next bytes are read. Read each part only once. The functions that read
   incrementally, like `read-line`, return the rest of the stream to continue
   with:

   ```
   match s.read-line
     Just((status, rest)) -> ... rest.read-bytes(n) ...
     Nothing -> ...
   ```

   Streams built from values (`bytes/stream`, `string/stream`) can be
   traversed any number of times.

   Reading a stream may not terminate, so the functions that consume one
   have the `div` effect. Functions that can fail on the input itself, like
   `read-line` with a `max-len`, need `exn` in the effect of the stream.
   Streams from files, sockets and processes have it already.
*/
module std/io/stream

pub import std/core/seq
import std/core/undiv

// A stream of bytes: a lazy sequence of chunks, read with effect `e`.
// Chunks may have any size, and can be empty.
pub alias byte-stream<e> = seq<e,bytes>

// ----------------------------------------------------------------------------
// Sources
// ----------------------------------------------------------------------------

// A stream of the bytes `b`, in chunks of at most `chunk-size` bytes.
pub fun bytes/stream( b : bytes, chunk-size : int = 65536 ) : byte-stream<e>
  chunks-from(b, 0, max(1, chunk-size))

fun chunks-from( b : bytes, ofs : int, size : int ) : byte-stream<e>
  seq/suspend fn()
    if ofs >= b.length then Done
    else Yield(b.subbytes(ofs, size), chunks-from(b, pretend-decreasing(ofs + size), size))

// A stream of the UTF-8 encoding of `s`, in chunks of at most `chunk-size` bytes.
pub fun string/stream( s : string, chunk-size : int = 65536 ) : byte-stream<e>
  s.bytes.stream(chunk-size)

// A stream that calls `read` for each chunk, until it returns an empty chunk.
// Each time a part of the stream is forced, `read` is called again: the
// stream is consumed as it is read.
pub fun from-reader( read : () -> <div|e> bytes ) : byte-stream<e>
  seq/suspend fn()
    val b = read()
    if b.is-empty then Done else Yield(b, from-reader(pretend-decreasing(read)))

// ----------------------------------------------------------------------------
// Splitting and decoding
// ----------------------------------------------------------------------------

// The index of the first byte `x` in `b` at or after `from`.
fun find-byte( b : bytes, x : int, from : int ) : maybe<int>
  val n = b.length
  fun go( i : int ) : maybe<int>
    if i >= n then Nothing
    elif b.unsafe-index(i.ssize_t).int == x then Just(i)
    else go(pretend-decreasing(i + 1))
  go(from)

// Split a stream at every `delim` byte (dropping the delimiters). A final
// record that does not end with `delim` is kept, unless it is empty.
pub fun split-bytes( s : byte-stream<e>, delim : int ) : seq<e,bytes>
  seq/suspend(fn() split-step(s, bytes/empty, 0, [], delim))

// `cur` is the current chunk, read up to `i`; `pend` holds the earlier parts
// of the current record (in reverse).
fun split-step( s : byte-stream<e>, cur : bytes, i : int, pend : list<bytes>, delim : int ) : <div|e> step<e,bytes>
  match cur.find-byte(delim, i)
    Just(j) ->
      val rec = Cons(cur.subbytes(i, j - i), pend).reverse.join
      Yield(rec, seq/suspend(fn() split-step(s, cur, pretend-decreasing(j + 1), [], delim)))
    Nothing ->
      val pend1 = if i < cur.length then Cons(cur.subbytes(i), pend) else pend
      match s.next
        Yield(chunk, rest) -> split-step(rest, chunk, 0, pend1, delim)
        Done -> if pend1.is-nil then Done else Yield(pend1.reverse.join, seq/empty())

// The lines of a UTF-8 stream, without the line terminators (`\n` or `\r\n`).
// A final line without a terminator is included unless it is empty.
pub fun stream/lines( s : byte-stream<e> ) : seq<e,string>
  s.split-bytes(10).map(fn(b) b.strip-cr.string)

fun strip-cr( b : bytes ) : bytes
  val n = b.length
  if n > 0 && b.unsafe-index((n - 1).ssize_t).int == 13 then b.subbytes(0, n - 1) else b

// Decode a UTF-8 stream into strings, one per chunk (a character that is split
// over two chunks is decoded as a whole). Invalid UTF-8 is decoded as for `bytes/string`.
pub fun decode-utf8( s : byte-stream<e> ) : seq<e,string>
  seq/suspend(fn() decode-step(s, bytes/empty))

fun decode-step( s : byte-stream<e>, carry : bytes ) : <div|e> step<e,string>
  match s.next
    Done -> if carry.is-empty then Done else Yield(carry.string, seq/empty())
    Yield(chunk, rest) ->
      val (str, post) = chunk.partial-string(carry)
      if str.is-empty then decode-step(rest, post)
      else Yield(str, seq/suspend(fn() decode-step(pretend-decreasing(rest), post)))

// Encode a sequence of strings as a UTF-8 stream.
pub fun encode-utf8( ss : seq<e,string> ) : byte-stream<e>
  ss.map(string/bytes)

// Encode lines as a UTF-8 stream, each followed by `\n`.
pub fun unlines( ss : seq<e,string> ) : byte-stream<e>
  ss.map(fn(l) (l ++ "\n").bytes)

// Regroup a stream into chunks of exactly `size` bytes (except the last one).
// This also combines many small chunks into fewer large ones, for example
// before writing them out.
pub fun rechunk( s : byte-stream<e>, size : int ) : byte-stream<e>
  seq/suspend(fn() rechunk-step(s, [], 0, max(1, size)))

// `pend` holds `plen` bytes (in reverse chunks) that are not yet emitted.
fun rechunk-step( s : byte-stream<e>, pend : list<bytes>, plen : int, size : int ) : <div|e> step<e,bytes>
  if plen >= size then slices(pend.reverse.join, 0, s, size)
  else match s.next
    Done -> if plen == 0 then Done else Yield(pend.reverse.join, seq/empty())
    Yield(c, rest) ->
      if c.is-empty then rechunk-step(rest, pend, plen, size)
      else rechunk-step(rest, Cons(c, pend), plen + c.length, size)

// Emit the full chunks of `buf` from `ofs` on, then continue with the rest of `s`.
fun slices( buf : bytes, ofs : int, s : byte-stream<e>, size : int ) : <div|e> step<e,bytes>
  val left = buf.length - ofs
  if left >= size then
    Yield(buf.subbytes(ofs, size), seq/suspend(fn() slices(buf, pretend-decreasing(ofs + size), s, size)))
  elif left == 0 then rechunk-step(s, [], 0, size)
  else rechunk-step(s, [buf.subbytes(ofs)], left, size)

// ----------------------------------------------------------------------------
// Buffered writing
// ----------------------------------------------------------------------------

// Writing through a buffer (see `buffered`).
pub effect buffered-write
  // Add bytes to the buffer (written out once enough have been collected).
  fun put-bytes( b : bytes ) : ()
  // Write out what the buffer holds now.
  fun flush-buffer() : ()

// Add text (as UTF-8) to the buffer.
pub fun put-text( s : string ) : buffered-write ()
  put-bytes(s.bytes)

// Run `action`, collecting what it writes with `put-bytes` (or `put-text`)
// and calling `write` only when at least `size` bytes are collected, and once
// more at the end (or on `flush-buffer`). Many small writes then become a few
// large ones, for example for a file handle or a socket, where every `write`
// is a system call:
//
// ```
// with-file("out.txt", Write) fn(h)
//   buffered(fn(b) h.write(b)) { list(1, 100000).foreach(fn(i) put-text(i.show ++ "\n")) }
// ```
//
// If `action` raises an exception, what it wrote after the last write is not
// written out.
pub fun buffered( write : bytes -> <div|e> (), action : () -> <buffered-write,div|e> a, size : int = 65536 ) : <div|e> a
  var pend : list<bytes> := []     // in reverse
  var plen := 0
  fun flush-now()
    if plen > 0 then
      val b = pend.reverse.join
      pend := []
      plen := 0
      write(b)
  val h = handler
    fun put-bytes(b)
      if !b.is-empty then
        pend := Cons(b, pend)
        plen := plen + b.length
        if plen >= size then flush-now()
    fun flush-buffer()
      flush-now()
  val x = h(action)
  flush-now()
  x

// The first `n` bytes of a stream.
pub fun take-bytes( s : byte-stream<e>, n : int ) : byte-stream<e>
  seq/suspend fn()
    if n <= 0 then Done else match s.next
      Done -> Done
      Yield(c, rest) ->
        if c.length >= n then Yield(c.subbytes(0, n), seq/empty())
        else Yield(c, pretend-decreasing(rest).take-bytes(n - c.length))

// A stream without its first `n` bytes.
pub fun drop-bytes( s : byte-stream<e>, n : int ) : byte-stream<e>
  seq/suspend(fn() drop-step(s, n))

fun drop-step( s : byte-stream<e>, n : int ) : <div|e> step<e,bytes>
  match s.next
    Done -> Done
    Yield(c, rest) ->
      if n <= 0 then Yield(c, rest)
      elif c.length > n then Yield(c.subbytes(n), rest)
      else drop-step(rest, n - c.length)

// ----------------------------------------------------------------------------
// Consuming
// ----------------------------------------------------------------------------

// Read the whole stream.
pub fun read-all( s : byte-stream<e> ) : <div|e> bytes
  s.foldl([], fn(acc, b) Cons(b, acc)).reverse.join

// Read the whole stream as UTF-8 text.
pub fun read-text( s : byte-stream<e> ) : <div|e> string
  s.read-all.string

// The total number of bytes in the stream.
pub fun byte-count( s : byte-stream<e> ) : <div|e> int
  s.foldl(0, fn(n, b) n + b.length)

// Write every chunk of the stream with `write`.
pub fun pipe( s : byte-stream<e>, write : bytes -> <div|e> () ) : <div|e> ()
  s.foreach(fn(b) if !b.is-empty then write(b))

// ----------------------------------------------------------------------------
// Reading incrementally
// ----------------------------------------------------------------------------

// Read up to and including the first `delim` byte. Returns the bytes before
// the delimiter and the rest of the stream after it, or `Nothing` if the
// stream ends first. If `max-len` is not negative and more than `max-len`
// bytes come before the delimiter, an exception is raised.
pub fun read-until( s : byte-stream<<exn|e>>, delim : int, max-len : int = -1 ) : <exn,div|e> maybe<(bytes, byte-stream<<exn|e>>)>
  until-step(s, delim, max-len, False, [], 0)

// With `at-end`, bytes at the end of the stream without a delimiter count as a record.
fun until-step( s : byte-stream<<exn|e>>, delim : int, max-len : int, at-end : bool, pend : list<bytes>, plen : int ) : <exn,div|e> maybe<(bytes, byte-stream<<exn|e>>)>
  match s.next
    Done -> if at-end && plen > 0 then Just((pend.reverse.join, seq/empty())) else Nothing
    Yield(c, rest) -> match c.find-byte(delim, 0)
      Just(j) ->
        if max-len >= 0 && plen + j > max-len then throw("std/io/stream/read-until: record too long", ExnRange)
        val rest1 = if j + 1 < c.length then seq/cons(c.subbytes(j + 1), rest) else rest
        Just((Cons(c.subbytes(0, j), pend).reverse.join, rest1))
      Nothing ->
        if max-len >= 0 && plen + c.length > max-len then throw("std/io/stream/read-until: record too long", ExnRange)
        until-step(rest, delim, max-len, at-end, Cons(c, pend), plen + c.length)

// Read one line (as UTF-8, without the terminator `\n` or `\r\n`) and return
// it with the rest of the stream. Returns `Nothing` at the end of the
// stream. A final line without a terminator is returned as a line too.
pub fun read-line( s : byte-stream<<exn|e>>, max-len : int = -1 ) : <exn,div|e> maybe<(string, byte-stream<<exn|e>>)>
  match until-step(s, 10, max-len, True, [], 0)
    Just((b, rest)) -> Just((b.strip-cr.string, rest))
    Nothing -> Nothing

// Read exactly `n` bytes, and return them with the rest of the stream. If
// the stream ends first, the bytes that were there are returned.
pub fun read-bytes( s : byte-stream<e>, n : int ) : <div|e> (bytes, byte-stream<e>)
  bytes-step(s, n, [])

fun bytes-step( s : byte-stream<e>, n : int, pend : list<bytes> ) : <div|e> (bytes, byte-stream<e>)
  if n <= 0 then (pend.reverse.join, s) else match s.next
    Done -> (pend.reverse.join, seq/empty())
    Yield(c, rest) ->
      if c.length > n then (Cons(c.subbytes(0, n), pend).reverse.join, seq/cons(c.subbytes(n), rest))
      else bytes-step(rest, n - c.length, Cons(c, pend))
