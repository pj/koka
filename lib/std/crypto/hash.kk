/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Cryptographic hash functions: SHA-256, BLAKE2b, BLAKE2s, BLAKE3, SHA-1
   (for legacy use only), and HMAC.

   ```
   "abc".bytes.sha256.hex-encode
   // "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
   hmac-sha256("key".bytes, "message".bytes).hex-encode
   "abc".bytes.blake3.hex-encode
   // "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
   ```

   BLAKE2 and BLAKE3 take an optional key, so they work as a MAC without
   HMAC, and their output size can be chosen.
*/
module std/crypto/hash

import std/text/encoding

extern import
  c  file "hash-inline.c"
  js file "hash-inline.js"

extern sha-digest( data : bytes, sha256 : bool ) : bytes
  c  "kk_sha_digest"
  js "_sha_digest"

extern blake2-digest( data : bytes, size : int, key : bytes, big : bool ) : bytes
  c  "kk_blake2_digest"
  js "_blake2_digest"

extern blake3-digest( data : bytes, size : int, key : bytes, mode : int ) : bytes
  c  "kk_blake3_digest"
  js "_blake3_digest"

// The SHA-256 digest (32 bytes) of `data`.
pub fun sha256( data : bytes ) : bytes
  sha-digest(data, True)

// The SHA-1 digest (20 bytes) of `data`. SHA-1 is broken for collision
// resistance; only use it for compatibility (e.g. git object ids).
pub fun sha1( data : bytes ) : bytes
  sha-digest(data, False)

// The BLAKE2b digest (RFC 7693) of `data`, of `size` bytes (1 to 64, by
// default 64). With a `key` (at most 64 bytes; longer keys are cut off),
// this is a keyed hash (a MAC).
pub fun blake2b( data : bytes, size : int = 64, key : bytes = bytes/empty ) : bytes
  blake2-digest(data, size, key, True)

// The BLAKE2s digest (RFC 7693) of `data`, of `size` bytes (1 to 32, by
// default 32). With a `key` (at most 32 bytes; longer keys are cut off),
// this is a keyed hash (a MAC).
pub fun blake2s( data : bytes, size : int = 32, key : bytes = bytes/empty ) : bytes
  blake2-digest(data, size, key, False)

// The BLAKE3 digest of `data`, of `size` bytes (32 by default; any size can
// be asked for, and a shorter output is a prefix of a longer one).
pub fun blake3( data : bytes, size : int = 32 ) : bytes
  blake3-digest(data, size, bytes/empty, 0)

// The BLAKE3 keyed hash (a MAC) of `data` with a 32-byte `key`.
pub fun blake3-keyed( key : bytes, data : bytes, size : int = 32 ) : exn bytes
  if key.length != 32 then throw("blake3-keyed: the key must have 32 bytes")
  blake3-digest(data, size, key, 1)

// Derive a key of `size` bytes from `material` with BLAKE3's key derivation
// mode. The `purpose` (BLAKE3's context string) should be a hard-coded, globally unique string that
// describes the application and purpose, like
// `"example.com 2026-11-08 session tokens v1"`.
pub fun blake3-derive-key( purpose : string, material : bytes, size : int = 32 ) : bytes
  blake3-digest(material, size, purpose.bytes, 2)

// The SHA-256 digest of a string (as UTF-8), as lower case hex.
pub fun string/sha256-hex( s : string ) : string
  s.bytes.sha256.hex-encode

// HMAC-SHA256 (RFC 2104) of `message` with `key`.
pub fun hmac-sha256( key : bytes, message : bytes ) : bytes
  hmac(key, message, sha256)

// HMAC-SHA1 (RFC 2104) of `message` with `key`.
pub fun hmac-sha1( key : bytes, message : bytes ) : bytes
  hmac(key, message, sha1)

fun hmac( key : bytes, message : bytes, h : bytes -> bytes ) : bytes
  val block-size = 64
  val k0 = if key.length > block-size then h(key) else key
  val k = k0.list ++ list(1, block-size - k0.length).map(fn(_) 0)
  val ipad = k.map(fn(x) xor8(x, 0x36)).vector.bytes
  val opad = k.map(fn(x) xor8(x, 0x5c)).vector.bytes
  h(opad ++ h(ipad ++ message))

// bitwise xor of two bytes (0..255)
fun xor8( a : int, b : int ) : int
  list(0, 7).foldl(0) fn(acc, i)
    val bit = 2 ^ i
    if ((a / bit) % 2) != ((b / bit) % 2) then acc + bit else acc

// Compare two byte sequences in constant time (for comparing MACs).
pub fun constant-time-equals( a : bytes, b : bytes ) : bool
  if a.length != b.length then False
  else zipwith(a.list, b.list, fn(x, y) xor8(x, y)).foldl(0, fn(acc, d) acc + d) == 0
