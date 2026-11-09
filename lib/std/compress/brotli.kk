/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Brotli compression (RFC 7932), as used by HTTP's `Content-Encoding: br`.

   ```
   import std/compress/brotli

   fun main()
     val data = "hello hello hello hello".bytes
     val packed = data.brotli
     println(packed.unbrotli.string)
   ```

   Streams (see `std/io/stream`) are (de)compressed as they are read:
   `h.stream.unbrotli.lines`.

   On the C backend this uses the brotli library (`libbrotlienc` and
   `libbrotlidec`). On the JavaScript backend it uses Node's `zlib`, which
   offers no synchronous incremental (de)compression: there the stream
   functions collect the whole input first, so they produce the same result
   but without the memory savings.
*/
module std/compress/brotli

pub import std/io/stream
import std/core/unsafe
import std/core/undiv

extern import
  c  { syslib="brotlienc" }

extern import
  c  { syslib="brotlidec" }

extern import
  c  { syslib="brotlicommon" }

extern import
  c  file "brotli-inline.c"
  js file "brotli-inline.js"

// Compress bytes. The `quality` goes from 0 (fastest) to 11 (best
// compression, the default); `window` is the base-2 logarithm of the window
// size, from 10 to 24 (-1: the default, 22).
pub fun brotli( b : bytes, quality : int = 11, window : int = -1 ) : bytes
  unsafe-total
    val z = br-new(True, quality, window)
    br-push(z, b, True).fst

// Decompress brotli data. Raises an exception if the data is not valid or
// incomplete.
pub fun unbrotli( b : bytes ) : exn bytes
  val (out, err) = pretend-no-ndet
    val z = br-new(False, -1, -1)
    br-push(z, b, True)
  check(err)
  out

fun check( err : string ) : exn ()
  if !err.is-empty then throw(err)

// Compress a stream as it is read. Each traversal of the result compresses
// the input again; like a stream from a file, the parts of one traversal
// should be read only once.
pub fun stream/brotli( s : byte-stream<<exn|e>>, quality : int = 11, window : int = -1 ) : byte-stream<<exn|e>>
  seq/suspend(fn() br-step(pretend-no-ndet { br-new(True, quality, window) }, s))

// Decompress a stream as it is read. Invalid or incomplete data raises an
// exception when that part of the stream is read.
pub fun stream/unbrotli( s : byte-stream<<exn|e>> ) : byte-stream<<exn|e>>
  seq/suspend(fn() br-step(pretend-no-ndet { br-new(False, -1, -1) }, s))

// Feed chunks to the (de)compressor `z` until it produces output.
fun br-step( z : any, s : byte-stream<<exn|e>> ) : <exn,div|e> step<<exn|e>,bytes>
  match s.next
    Done ->
      val (out, err) = pretend-no-ndet { br-push(z, bytes/empty, True) }
      check(err)
      if out.is-empty then Done else Yield(out, seq/empty())
    Yield(chunk, rest) ->
      val (out, err) = pretend-no-ndet { br-push(z, chunk, False) }
      check(err)
      if out.is-empty then br-step(z, rest)
      else Yield(out, seq/suspend(fn() br-step(z, pretend-decreasing(rest))))

extern br-new( compress : bool, quality : int, window : int ) : ndet any
  c  "kk_br_new"
  js "_br_new"

// Returns the output and an error message (empty if there is none).
extern br-push( z : any, input : bytes, finish : bool ) : ndet (bytes, string)
  c  "kk_br_push"
  js "_br_push"
