/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Compression: deflate, zlib and gzip.

   Compress bytes at once,

   ```
   import std/compress

   fun main()
     val data = "hello hello hello hello".bytes
     val packed = data.gzip
     println(packed.gunzip.string)
   ```

   or compress and decompress byte streams (see `std/io/stream`) as they are
   read:

   ```
   with-file("access.log.gz".path, Read) fn(h)
     h.stream.gunzip.lines.foreach(println)
   ```

   On the C backend this uses zlib. On the JavaScript backend it uses Node's
   `zlib`, which offers no synchronous incremental (de)compression: there the
   stream functions collect the whole input first, so they produce the same
   result but without the memory savings.
*/
module std/compress

pub import std/io/stream
import std/core/unsafe
import std/core/undiv

extern import
  c  { syslib="z" }

extern import
  c  file "compress-inline.c"
  js file "compress-inline.js"

// A compressed data format.
pub type format
  // Raw deflate data (RFC 1951), without a header or checksum.
  Deflate
  // The zlib format (RFC 1950): deflate data with a small header and an Adler-32 checksum.
  Zlib
  // The gzip format (RFC 1952), as used by `gzip` and HTTP's `Content-Encoding: gzip`.
  Gzip
  // When decompressing: gzip or zlib, whichever the data is. (Compresses as gzip.)
  Auto

fun format/code( f : format ) : int
  match f
    Deflate -> 0
    Zlib    -> 1
    Gzip    -> 2
    Auto    -> 3

// ----------------------------------------------------------------------------
// Compressing bytes
// ----------------------------------------------------------------------------

// Compress bytes in the given `format` (`Gzip` by default). The `level` goes
// from 0 (no compression) to 9 (best compression); -1 is zlib's default (6).
pub fun compress( b : bytes, format : format = Gzip, level : int = -1 ) : bytes
  unsafe-total
    val z = zs-new(True, format.code, level)
    zs-push(z, b, True).fst

// Decompress bytes in the given `format` (`Auto` by default: gzip or zlib).
// Raises an exception if the data is not valid or incomplete.
pub fun decompress( b : bytes, format : format = Auto ) : exn bytes
  val (out, err) = pretend-no-ndet
    val z = zs-new(False, format.code, -1)
    zs-push(z, b, True)
  check(err)
  out

// Compress bytes as gzip.
pub fun gzip( b : bytes, level : int = -1 ) : bytes
  b.compress(Gzip, level)

// Decompress gzip data (also if it has several gzip members after another).
pub fun gunzip( b : bytes ) : exn bytes
  b.decompress(Gzip)

// Compress bytes as raw deflate data.
pub fun deflate( b : bytes, level : int = -1 ) : bytes
  b.compress(Deflate, level)

// Decompress raw deflate data.
pub fun inflate( b : bytes ) : exn bytes
  b.decompress(Deflate)

fun check( err : string ) : exn ()
  if !err.is-empty then throw(err)

// ----------------------------------------------------------------------------
// Compressing streams
// ----------------------------------------------------------------------------

// Compress a stream in the given `format` (`Gzip` by default) as it is read.
// Each traversal of the result compresses the input again; like a stream from
// a file, the parts of one traversal should be read only once.
pub fun stream/compress( s : byte-stream<<exn|e>>, format : format = Gzip, level : int = -1 ) : byte-stream<<exn|e>>
  seq/suspend(fn() zs-step(pretend-no-ndet { zs-new(True, format.code, level) }, s))

// Decompress a stream in the given `format` (`Auto` by default: gzip or
// zlib) as it is read. Invalid or incomplete data raises an exception when
// that part of the stream is read.
pub fun stream/decompress( s : byte-stream<<exn|e>>, format : format = Auto ) : byte-stream<<exn|e>>
  seq/suspend(fn() zs-step(pretend-no-ndet { zs-new(False, format.code, -1) }, s))

// Compress a stream as gzip.
pub fun stream/gzip( s : byte-stream<<exn|e>>, level : int = -1 ) : byte-stream<<exn|e>>
  s.compress(Gzip, level)

// Decompress a gzip stream.
pub fun stream/gunzip( s : byte-stream<<exn|e>> ) : byte-stream<<exn|e>>
  s.decompress(Gzip)

// Feed chunks to the (de)compressor `z` until it produces output.
fun zs-step( z : any, s : byte-stream<<exn|e>> ) : <exn,div|e> step<<exn|e>,bytes>
  match s.next
    Done ->
      val (out, err) = pretend-no-ndet { zs-push(z, bytes/empty, True) }
      check(err)
      if out.is-empty then Done else Yield(out, seq/empty())
    Yield(chunk, rest) ->
      val (out, err) = pretend-no-ndet { zs-push(z, chunk, False) }
      check(err)
      if out.is-empty then zs-step(z, rest)
      else Yield(out, seq/suspend(fn() zs-step(z, pretend-decreasing(rest))))

// ----------------------------------------------------------------------------
// Checksums
// ----------------------------------------------------------------------------

// The CRC-32 checksum of `b` (as used by gzip, zip and PNG). To checksum data
// in parts, pass the checksum of the earlier parts as `init`.
pub fun crc32( b : bytes, init : int = 0 ) : int
  zs-crc32(b, init)

// The Adler-32 checksum of `b` (as used by zlib). To checksum data in parts,
// pass the checksum of the earlier parts as `init`.
pub fun adler32( b : bytes, init : int = 1 ) : int
  zs-adler32(b, init)

// ----------------------------------------------------------------------------
// Primitives
// ----------------------------------------------------------------------------

// (`ndet` keeps these stateful calls in order; the functions above hide it.)
extern zs-new( compress : bool, format : int, level : int ) : ndet any
  c  "kk_zs_new"
  js "_zs_new"

// Feed input; returns the output so far and an error message (empty if none).
extern zs-push( z : any, input : bytes, finish : bool ) : ndet (bytes, string)
  c  "kk_zs_push"
  js "_zs_push"

extern zs-crc32( b : bytes, init : int ) : int
  c  "kk_zs_crc32"
  js "_zs_crc32"

extern zs-adler32( b : bytes, init : int ) : int
  c  "kk_zs_adler32"
  js "_zs_adler32"
