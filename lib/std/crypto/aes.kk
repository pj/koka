/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* AES encryption (FIPS-197) and PBKDF2 key derivation (RFC 8018).

   ```
   import std/crypto/aes

   fun main()
     val key = pbkdf2-sha256("correct horse".bytes, "salt".bytes, 100000, 32)
     val iv = random-bytes(16)
     val secret = aes-ctr(key, iv, "attack at dawn".bytes)
     println(aes-ctr(key, iv, secret).string)   // attack at dawn
   ```

   Keys have 16, 24 or 32 bytes (AES-128, AES-192, AES-256). CTR mode
   encrypts and decrypts with the same function. These are building blocks:
   CTR mode does not authenticate the data, so combine it with a MAC (such
   as `hmac-sha256` over the ciphertext) and never reuse a key with the same IV.
*/
module std/crypto/aes

import std/crypto/hash
import std/core/undiv
import std/num/random
import std/num/int32

extern import
  c  file "aes-inline.c"
  js file "aes-inline.js"

fun check-key( key : bytes ) : exn ()
  if key.length != 16 && key.length != 24 && key.length != 32 then
    throw("aes: the key must have 16, 24 or 32 bytes (it has " ++ key.length.show ++ ")")

// Encrypt `data` (a multiple of 16 bytes) block by block (ECB mode). Only
// use this to build other modes: ECB shows which blocks are equal.
pub fun aes-ecb-encrypt( key : bytes, data : bytes ) : exn bytes
  check-key(key)
  if data.length % 16 != 0 then throw("aes: ECB data must be a multiple of 16 bytes")
  if data.is-empty then data else prim-aes-ecb-encrypt(key, data)

// Encrypt (or decrypt) `data` in CTR mode with a 16-byte initial counter
// `iv`, incremented as a big-endian number (NIST SP 800-38A).
pub fun aes-ctr( key : bytes, iv : bytes, data : bytes ) : exn bytes
  check-key(key)
  if iv.length != 16 then throw("aes: the counter (iv) must have 16 bytes")
  if data.is-empty then data else prim-aes-ctr(key, iv, data, False)

// CTR mode with a little-endian counter (as in WinZip AES encryption).
pub fun aes-ctr-le( key : bytes, iv : bytes, data : bytes ) : exn bytes
  check-key(key)
  if iv.length != 16 then throw("aes: the counter (iv) must have 16 bytes")
  if data.is-empty then data else prim-aes-ctr(key, iv, data, True)

// `n` random bytes from the strong random generator (for keys, IVs and salts).
pub fun random-bytes( n : int ) : ndet bytes
  list(1, n).map(fn(_) srandom-int32-range(0.int32, 256.int32).int).vector.bytes

// The bitwise xor of two byte strings (as long as the shorter one).
pub fun xor-bytes( a : bytes, b : bytes ) : bytes
  prim-bytes-xor(a, b)

// PBKDF2 (RFC 8018) with an HMAC: derive `size` bytes from a password and a
// salt, slowed down by `iterations`.
pub fun pbkdf2( password : bytes, salt : bytes, iterations : int, size : int, prf : (bytes, bytes) -> bytes ) : bytes
  val hlen = prf(password, bytes/empty).length
  val nblocks = (size + hlen - 1) / hlen
  list(1, nblocks).map(fn(i) pbkdf2-block(password, salt, iterations, prf, i)).join.subbytes(0, size)

fun pbkdf2-block( password : bytes, salt : bytes, iterations : int, prf : (bytes, bytes) -> bytes, i : int ) : bytes
  val index = [(i / 0x1000000) % 256, (i / 0x10000) % 256, (i / 0x100) % 256, i % 256].vector.bytes
  val u1 = prf(password, salt ++ index)
  fun step( n : int, u : bytes, t : bytes ) : bytes
    if n <= 1 then t
    else
      val u2 = prf(password, u)
      step(pretend-decreasing(n - 1), u2, xor-bytes(t, u2))
  step(iterations, u1, u1)

// PBKDF2 with HMAC-SHA1.
pub fun pbkdf2-sha1( password : bytes, salt : bytes, iterations : int, size : int ) : bytes
  pbkdf2(password, salt, iterations, size, hmac-sha1)

// PBKDF2 with HMAC-SHA256.
pub fun pbkdf2-sha256( password : bytes, salt : bytes, iterations : int, size : int ) : bytes
  pbkdf2(password, salt, iterations, size, hmac-sha256)

extern prim-aes-ecb-encrypt( key : bytes, data : bytes ) : bytes
  c  "kk_aes_ecb_encrypt"
  js "_aes_ecb_encrypt"

extern prim-aes-ctr( key : bytes, iv : bytes, data : bytes, little : bool ) : bytes
  c  "kk_aes_ctr"
  js "_aes_ctr"

extern prim-bytes-xor( a : bytes, b : bytes ) : bytes
  c  "kk_bytes_xor"
  js "_bytes_xor"
