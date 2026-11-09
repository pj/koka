/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Zip archives: reading and writing.

   ```
   import std/compress/zip

   fun main()
     val archive = zip-write([zip-file("hello.txt", "hello world".bytes), zip-file("docs/", bytes/empty)])
     zip-read(archive).foreach fn(e)
       println(e.name ++ ": " ++ e.data.length.show ++ " bytes")
   ```

   Entries are stored or compressed with deflate (the methods every zip
   tool understands), and their CRC-32 is checked when reading. Zip64
   archives (over 4 GiB or 65535 entries), encryption and spanned archives
   are not supported.
*/
module std/compress/zip

import std/compress
import std/core/undiv

// An entry of an archive. A name ending in `/` is a directory.
pub struct zip-entry
  name : string
  data : bytes
  compress : bool = True    // when writing: compress with deflate (if that makes it smaller)
  unix-mode : int = 0       // when non-zero: the Unix permissions (like 0x1A4 for 0644)

// A file entry.
pub fun zip-file( name : string, data : bytes, compress : bool = True ) : zip-entry
  Zip-entry(name, data, compress)

// Is the entry a directory?
pub fun is-directory( e : zip-entry ) : bool
  e.name.ends-with("/").is-just

// ----------------------------------------------------------------------------
// Little-endian numbers
// ----------------------------------------------------------------------------

fun u8( b : bytes, i : int ) : int
  if i < 0 || i >= b.length then 0 else b.unsafe-index(i.ssize_t).int

fun u16( b : bytes, i : int ) : int
  b.u8(i) + 256 * b.u8(i + 1)

fun u32( b : bytes, i : int ) : int
  b.u16(i) + 65536 * b.u16(i + 2)

fun le16( n : int ) : list<int>
  [n % 256, (n / 256) % 256]

fun le32( n : int ) : list<int>
  le16(n % 65536) ++ le16((n / 65536) % 65536)

fun ints( xs : list<int> ) : bytes
  xs.vector.bytes

// ----------------------------------------------------------------------------
// Reading
// ----------------------------------------------------------------------------

// Find the end of central directory record (the last one, before a possible comment).
fun find-eocd( b : bytes ) : exn int
  val n = b.length
  fun go( i : int ) : exn int
    if i < 0 || i < n - 22 - 65535 then throw("zip: not a zip archive (no end of central directory)")
    elif b.u32(i) == 0x06054b50 then i
    else go(pretend-decreasing(i - 1))
  go(n - 22)

// Read the entries of an archive.
pub fun zip-read( b : bytes ) : exn list<zip-entry>
  val eocd = find-eocd(b)
  val count = b.u16(eocd + 10)
  val cd-offset = b.u32(eocd + 16)
  if count == 0xFFFF || cd-offset == 0xFFFFFFFF then throw("zip: zip64 archives are not supported")
  read-central(b, cd-offset, count, [])

fun read-central( b : bytes, at : int, left : int, acc : list<zip-entry> ) : exn list<zip-entry>
  if left <= 0 then acc.reverse
  else
    if b.u32(at) != 0x02014b50 then throw("zip: invalid central directory entry")
    val flags = b.u16(at + 8)
    val method = b.u16(at + 10)
    val crc = b.u32(at + 16)
    val csize = b.u32(at + 20)
    val usize = b.u32(at + 24)
    val name-len = b.u16(at + 28)
    val extra-len = b.u16(at + 30)
    val comment-len = b.u16(at + 32)
    val attrs = b.u32(at + 38)
    val local = b.u32(at + 42)
    val entry-name = b.subbytes(at + 46, name-len).string
    val name = entry-name
    if flags % 2 == 1 then throw("zip: " ++ name ++ " is encrypted")
    if b.u32(local) != 0x04034b50 then throw("zip: invalid local header for " ++ name)
    val data-start = local + 30 + b.u16(local + 26) + b.u16(local + 28)
    val packed-data = b.subbytes(data-start, csize)
    if packed-data.length != csize then throw("zip: " ++ name ++ " is cut off")
    val data = match method
      0 -> packed-data
      8 -> match try({ packed-data.inflate })
        Ok(d) -> d
        Error(e) -> throw("zip: " ++ name ++ ": " ++ e.message)
      _ -> throw("zip: " ++ name ++ " uses an unsupported compression method (" ++ method.show ++ ")")
    if data.length != usize then throw("zip: " ++ name ++ " has the wrong size")
    if crc32(data) != crc then throw("zip: " ++ name ++ " has a wrong checksum")
    val made-by-unix = b.u8(at + 5) == 3
    val mode = if made-by-unix then (attrs / 65536) % 0x1000 else 0
    val e = Zip-entry(name, data, method == 8, mode)
    read-central(b, pretend-decreasing(at + 46 + name-len + extra-len + comment-len), left - 1, Cons(e, acc))

// Read one entry by name.
pub fun zip-find( b : bytes, entry-name : string ) : exn maybe<zip-entry>
  zip-read(b).find(fn(e) e.name == entry-name)

// ----------------------------------------------------------------------------
// Writing
// ----------------------------------------------------------------------------

// 1980-01-01 00:00 in MS-DOS format: zip entries get a fixed time, so that
// the same entries always give the same archive.
val dos-time = 0
val dos-date = (0 * 512) + (1 * 32) + 1

// Write an archive with the entries, in order.
pub fun zip-write( entries : list<zip-entry> ) : exn bytes
  if entries.length >= 0xFFFF then throw("zip: too many entries (zip64 is not supported)")
  val (locals, centrals, _) = entries.foldl(([], [], 0)) fn((ls, cs, offset), e)
    val name-bytes = e.name.bytes
    val crc = crc32(e.data)
    val packed = if e.compress && !e.is-directory then e.data.deflate else e.data
    val (method, stored) = if e.compress && !e.is-directory && packed.length < e.data.length then (8, packed) else (0, e.data)
    if offset + stored.length >= 0xFFFFFFFF then throw("zip: the archive is too large (zip64 is not supported)")
    val utf8-flag = if e.name.list.any(fn(c) c.int >= 0x80) then 0x800 else 0
    val common = le16(utf8-flag) ++ le16(method) ++ le16(dos-time) ++ le16(dos-date) ++ le32(crc)
                 ++ le32(stored.length) ++ le32(e.data.length) ++ le16(name-bytes.length) ++ le16(0)
    val local = ints(le32(0x04034b50) ++ le16(20) ++ common) ++ name-bytes ++ stored
    val mode = if e.unix-mode != 0 then e.unix-mode elif e.is-directory then 0x1ED else 0x1A4
    val kind = if e.is-directory then 0x4000 else 0x8000
    val ext-attrs = (kind + mode) * 65536 + (if e.is-directory then 0x10 else 0)
    val central = ints(le32(0x02014b50) ++ [20, 3] ++ le16(20) ++ common ++ le16(0) ++ le16(0) ++ le16(0)
                       ++ le32(ext-attrs) ++ le32(offset)) ++ name-bytes
    (Cons(local, ls), Cons(central, cs), offset + local.length)
  val body = locals.reverse.join
  val cd = centrals.reverse.join
  val eocd = ints(le32(0x06054b50) ++ le16(0) ++ le16(0) ++ le16(entries.length) ++ le16(entries.length)
                  ++ le32(cd.length) ++ le32(body.length) ++ le16(0))
  body ++ cd ++ eocd
