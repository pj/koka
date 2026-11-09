/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Zstandard compression (RFC 8878), as used by `zstd` and HTTP's
   `Content-Encoding: zstd`.

   ```
   import std/compress/zstd

   fun main()
     val data = "hello hello hello hello".bytes
     val packed = data.zstd
     println(packed.unzstd.string)
   ```

   Streams (see `std/io/stream`) are (de)compressed as they are read:
   `h.stream.unzstd.lines`.

   On the C backend this uses `libzstd`. On the JavaScript backend it uses
   Node's `zlib` (Node 22.15 or later), which offers no synchronous
   incremental (de)compression: there the stream functions collect the whole
   input first, so they produce the same result but without the memory
   savings.
*/
module std/compress/zstd

pub import std/io/stream
import std/core/unsafe
import std/core/undiv

extern import
  c  { syslib="zstd" }

extern import
  c  file "zstd-inline.c"
  js file "zstd-inline.js"

// Compress bytes. The `level` goes from 1 (fastest) to 19 (best compression;
// up to 22 uses much more memory); the default is 3. Negative levels are even
// faster. The output includes a checksum of the data.
pub fun zstd( b : bytes, level : int = 3 ) : bytes
  unsafe-total
    val z = zs-new(True, level)
    zs-push(z, b, True).fst

// Decompress zstd data (also if it has several frames after another). Raises
// an exception if the data is not valid or incomplete.
pub fun unzstd( b : bytes ) : exn bytes
  val (out, err) = pretend-no-ndet
    val z = zs-new(False, 0)
    zs-push(z, b, True)
  check(err)
  out

fun check( err : string ) : exn ()
  if !err.is-empty then throw(err)

// Compress a stream as it is read. Each traversal of the result compresses
// the input again; like a stream from a file, the parts of one traversal
// should be read only once.
pub fun stream/zstd( s : byte-stream<<exn|e>>, level : int = 3 ) : byte-stream<<exn|e>>
  seq/suspend(fn() zs-step(pretend-no-ndet { zs-new(True, level) }, s))

// Decompress a stream as it is read. Invalid or incomplete data raises an
// exception when that part of the stream is read.
pub fun stream/unzstd( s : byte-stream<<exn|e>> ) : byte-stream<<exn|e>>
  seq/suspend(fn() zs-step(pretend-no-ndet { zs-new(False, 0) }, s))

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

extern zs-new( compress : bool, level : int ) : ndet any
  c  "kk_zstd_new"
  js "_zstd_new"

// Returns the output and an error message (empty if there is none).
extern zs-push( z : any, input : bytes, finish : bool ) : ndet (bytes, string)
  c  "kk_zstd_push"
  js "_zstd_push"
