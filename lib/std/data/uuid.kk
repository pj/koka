/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* UUIDs (RFC 9562).

   ```
   val id = new-uuid-v4()          // random, e.g. 3f0c9a3e-6c1b-4f0e-9d2a-0b8e4c7d1a55
   val ts = new-uuid-v7()          // time-ordered
   parse-uuid(id.show) == Just(id)
   ```
*/
module std/data/uuid

import std/num/random
import std/text/encoding

// A UUID, stored as two 64-bit halves (as non-negative integers).
pub value struct uuid
  hi : int
  lo : int

val two64 = 0x1_0000_0000_0000_0000

// The nil UUID `00000000-0000-0000-0000-000000000000`.
pub val nil-uuid : uuid = Uuid(0, 0)

fun random-bits( n : int ) : random int
  // n is a multiple of 16
  list(1, n / 16).foldl(0, fn(acc, _) acc * 65536 + (random-int() % 65536).abs)

// Generate a random (version 4) UUID using the given `random` handler.
pub fun random-uuid-v4() : random uuid
  val hi = random-bits(64)
  val lo = random-bits(64)
  // version 4 in bits 12-15 of time_hi_and_version; variant 10 in the top bits of lo
  val hi' = (hi / 65536) * 65536 + 0x4000 + (hi % 4096)
  val lo' = 0x8000_0000_0000_0000 + (lo % 0x4000_0000_0000_0000)
  Uuid(hi', lo')

// Generate a random (version 4) UUID using a cryptographically strong random source.
pub fun new-uuid-v4() : ndet uuid
  strong-random(random-uuid-v4)

// Generate a time-ordered (version 7) UUID: the Unix time in milliseconds
// followed by random bits.
pub fun new-uuid-v7() : ndet uuid
  val ms = unix-time-ms() % 0x1_0000_0000_0000
  strong-random fn()
    val rand-a = random-bits(16) % 4096
    val lo = random-bits(64)
    Uuid(ms * 65536 + 0x7000 + rand-a, 0x8000_0000_0000_0000 + (lo % 0x4000_0000_0000_0000))

// The version of the UUID (4 for random, 7 for time-ordered, ...).
pub fun version( u : uuid ) : int
  (u.hi / 4096) % 16

// The 16 bytes of the UUID (big-endian).
pub fun uuid/bytes( u : uuid ) : bytes
  val hex = u.hex
  hex.hex-decode.default(bytes/empty)

fun hex( u : uuid ) : string
  u.hi.show-hex(16, use-capitals=False, pre="") ++ u.lo.show-hex(16, use-capitals=False, pre="")

// Show a UUID in the canonical form `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.
pub fun show( u : uuid ) : string
  val h = u.hex.list
  [h.take(8), h.drop(8).take(4), h.drop(12).take(4), h.drop(16).take(4), h.drop(20)].map(string).join("-")

// Parse a UUID in canonical form (case insensitive; also accepts `{...}` and `urn:uuid:` forms).
pub fun parse-uuid( s : string ) : maybe<uuid>
  val s1 = match s.starts-with("urn:uuid:") { Just(sl) -> sl.string; Nothing -> s }
  val s2 = if s1.starts-with("{").is-just && s1.ends-with("}").is-just then s1.list.drop(1).take(36).string else s1
  val parts = s2.split("-")
  if parts.map(count) != [8,4,4,4,12] then return Nothing
  val hex = parts.join
  if !hex.list.all(is-hex-digit) then return Nothing
  match (parse-int(hex.list.take(16).string, hex=True), parse-int(hex.list.drop(16).string, hex=True))
    (Just(hi), Just(lo)) -> Just(Uuid(hi, lo))
    _ -> Nothing

pub fun (==)( a : uuid, b : uuid ) : bool
  a.hi == b.hi && a.lo == b.lo

pub fun cmp( a : uuid, b : uuid ) : order
  match cmp(a.hi, b.hi)
    Eq -> cmp(a.lo, b.lo)
    o -> o

extern unix-time-ms() : ndet int
  c  inline "kk_integer_from_int64(kk_time_unix_now(kk_context()).seconds * 1000 + kk_time_unix_now(kk_context()).attoseconds / 1000000000000000LL, kk_context())"
  js inline "Date.now()"
