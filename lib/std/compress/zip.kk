/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Zip archives: reading and writing, with zip64 and encryption.

   ```
   import std/compress/zip

   fun main()
     val archive = zip-write([zip-file("hello.txt", "hello world".bytes), zip-file("docs/", bytes/empty)])
     zip-read(archive).foreach fn(e)
       println(e.name ++ ": " ++ e.data.length.show ++ " bytes")
     // encrypted with AES-256 (WinZip format), read back with the password
     val secret = zip-write([zip-file("key.txt", "s3cr3t".bytes, password = "hunter2")])
     println(zip-read(secret, password = "hunter2").map(fn(e) e.data.string))
   ```

   Entries are stored or compressed with deflate (the methods every zip
   tool understands), and their CRC-32 is checked when reading. Large
   archives use the zip64 format automatically (also on request with
   `zip64 = True`). Entries can be encrypted with WinZip AES (AES-128/192/256,
   the default) or traditional ZipCrypto, which is weak and only meant for
   tools that know nothing else. Spanned archives are not supported.
*/
module std/compress/zip

import std/compress
import std/core/undiv
import std/crypto/aes
import std/crypto/hash

extern import
  c  file "zip-inline.c"
  js file "zip-inline.js"

// How an entry is encrypted.
pub type zip-encryption
  No-encryption
  // Traditional PKWARE encryption: weak, but understood by every zip tool.
  Zip-crypto
  // WinZip AES encryption with a 128, 192 or 256-bit key.
  Aes128
  Aes192
  Aes256

pub fun zip-encryption/show( e : zip-encryption ) : string
  match e
    No-encryption -> "none"
    Zip-crypto -> "zipcrypto"
    Aes128 -> "aes-128"
    Aes192 -> "aes-192"
    Aes256 -> "aes-256"

// An entry of an archive. A name ending in `/` is a directory.
pub struct zip-entry
  name : string
  data : bytes
  compress : bool = True                  // when writing: compress with deflate (if that makes it smaller)
  unix-mode : int = 0                     // when non-zero: the Unix permissions (like 0x1A4 for 0644)
  password : string = ""                  // when writing: encrypt the entry with this password
  encryption : zip-encryption = Aes256    // when writing with a password: how; when reading: how it was encrypted

// A file entry; with a `password` it is encrypted (with AES-256 by default).
pub fun zip-file( name : string, data : bytes, compress : bool = True, password : string = "", encryption : zip-encryption = Aes256 ) : zip-entry
  Zip-entry(name, data, compress, 0, password, if password.is-empty then No-encryption else encryption)

// Is the entry a directory?
pub fun is-directory( e : zip-entry ) : bool
  e.name.ends-with("/").is-just

// Was the entry encrypted (when read)?
pub fun is-encrypted( e : zip-entry ) : bool
  match e.encryption
    No-encryption -> False
    _ -> True

// ----------------------------------------------------------------------------
// Little-endian numbers
// ----------------------------------------------------------------------------

fun u8( b : bytes, i : int ) : int
  if i < 0 || i >= b.length then 0 else b.unsafe-index(i.ssize_t).int

fun u16( b : bytes, i : int ) : int
  b.u8(i) + 256 * b.u8(i + 1)

fun u32( b : bytes, i : int ) : int
  b.u16(i) + 65536 * b.u16(i + 2)

fun u64( b : bytes, i : int ) : int
  b.u32(i) + 0x100000000 * b.u32(i + 4)

fun le16( n : int ) : list<int>
  [n % 256, (n / 256) % 256]

fun le32( n : int ) : list<int>
  le16(n % 65536) ++ le16((n / 65536) % 65536)

fun le64( n : int ) : list<int>
  le32(n % 0x100000000) ++ le32(n / 0x100000000)

fun ints( xs : list<int> ) : bytes
  xs.vector.bytes

val max32 = 0xFFFFFFFF
val max16 = 0xFFFF

// ----------------------------------------------------------------------------
// Encryption
// ----------------------------------------------------------------------------

extern prim-zipcrypto( password : bytes, data : bytes, decrypt : bool ) : bytes
  c  "kk_zipcrypto"
  js "_zipcrypto"

fun aes-key-length( e : zip-encryption ) : int
  match e
    Aes128 -> 16
    Aes192 -> 24
    _ -> 32

fun aes-strength( e : zip-encryption ) : int
  match e
    Aes128 -> 1
    Aes192 -> 2
    _ -> 3

// The encryption key, the authentication key and the password check value.
fun aes-keys( password : string, salt : bytes, keylen : int ) : (bytes, bytes, bytes)
  val k = pbkdf2-sha1(password.bytes, salt, 1000, 2 * keylen + 2)
  (k.subbytes(0, keylen), k.subbytes(keylen, keylen), k.subbytes(2 * keylen, 2))

val aes-iv = ([1] ++ list(1, 15).map(fn(_) 0)).vector.bytes

fun hex-text( b : bytes ) : string
  b.list.map(fn(x) x.show-hex(2, pre = "")).join

fun aes-encrypt( password : string, enc : zip-encryption, data : bytes ) : <exn,ndet> bytes
  val keylen = enc.aes-key-length
  val salt = random-bytes(keylen / 2)   // 8, 12 or 16 bytes
  val (key, auth, check) = aes-keys(password, salt, keylen)
  val cipher = aes-ctr-le(key, aes-iv, data)
  val mac = hmac-sha1(auth, cipher).subbytes(0, 10)
  salt ++ check ++ cipher ++ mac

fun aes-decrypt( name : string, password : string, strength : int, data : bytes ) : exn bytes
  val keylen = match strength
    1 -> 16
    2 -> 24
    3 -> 32
    _ -> throw("zip: " ++ name ++ " has an unknown AES key strength")
  val saltlen = keylen / 2
  if data.length < saltlen + 12 then throw("zip: " ++ name ++ " is cut off")
  val (key, auth, check) = aes-keys(password, data.subbytes(0, saltlen), keylen)
  if check.hex-text != data.subbytes(saltlen, 2).hex-text then throw("zip: wrong password for " ++ name)
  val cipher = data.subbytes(saltlen + 2, data.length - saltlen - 12)
  if hmac-sha1(auth, cipher).subbytes(0, 10).hex-text != data.subbytes(data.length - 10, 10).hex-text then
    throw("zip: " ++ name ++ " was changed (its authentication code does not match)")
  aes-ctr-le(key, aes-iv, cipher)

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

// Read the entries of an archive; encrypted entries need the `password`.
pub fun zip-read( b : bytes, password : string = "" ) : exn list<zip-entry>
  val eocd = find-eocd(b)
  val count16 = b.u16(eocd + 10)
  val offset32 = b.u32(eocd + 16)
  val (count, cd-offset) =
    if count16 == max16 || offset32 == max32 then
      // zip64: the locator just before the end record points to the zip64 end record
      val loc = eocd - 20
      if loc < 0 || b.u32(loc) != 0x07064b50 then throw("zip: zip64 end of central directory locator missing")
      val rec = b.u64(loc + 8)
      if b.u32(rec) != 0x06064b50 then throw("zip: invalid zip64 end of central directory")
      (b.u64(rec + 32), b.u64(rec + 48))
    else (count16, offset32)
  read-central(b, cd-offset, count, password, [])

// The extra field with header `id` in `extra .. extra+len`: the offset of its data.
fun find-extra( b : bytes, extra : int, len : int, id : int ) : maybe<int>
  fun find( at : int ) : maybe<int>
    if at + 4 > extra + len then Nothing
    elif b.u16(at) == id then Just(at + 4)
    else find(pretend-decreasing(at + 4 + b.u16(at + 2)))
  find(extra)

// The zip64 extra field values (in order: size, compressed size, offset) for the fields that are `0xFFFFFFFF`.
fun zip64-values( b : bytes, extra : int, extra-len : int, wanted : list<bool> ) : list<maybe<int>>
  match b.find-extra(extra, extra-len, 0x0001)
    Nothing -> wanted.map(fn(_) Nothing)
    Just(start) ->
      val (_, vals) = wanted.foldl((start, [])) fn((pos, acc), w)
        if w then (pos + 8, Cons(Just(b.u64(pos)), acc)) else (pos, Cons(Nothing, acc))
      vals.reverse

fun read-central( b : bytes, at : int, left : int, password : string, acc : list<zip-entry> ) : exn list<zip-entry>
  if left <= 0 then acc.reverse
  else
    if b.u32(at) != 0x02014b50 then throw("zip: invalid central directory entry")
    val name-len = b.u16(at + 28)
    val extra-len = b.u16(at + 30)
    val comment-len = b.u16(at + 32)
    val e = read-entry(b, at, password)
    read-central(b, pretend-decreasing(at + 46 + name-len + extra-len + comment-len), left - 1, password, Cons(e, acc))

fun read-entry( b : bytes, at : int, password : string ) : exn zip-entry
  val flags = b.u16(at + 8)
  val method0 = b.u16(at + 10)
  val dtime = b.u16(at + 12)
  val crc = b.u32(at + 16)
  val csize0 = b.u32(at + 20)
  val usize0 = b.u32(at + 24)
  val name-len = b.u16(at + 28)
  val extra-len = b.u16(at + 30)
  val attrs = b.u32(at + 38)
  val local0 = b.u32(at + 42)
  val name = b.subbytes(at + 46, name-len).string
  val extra = at + 46 + name-len
  val z64 = zip64-values(b, extra, extra-len, [usize0 == max32, csize0 == max32, local0 == max32])
  val usize = match z64 { [Just(v), _, _] -> v; _ -> usize0 }
  val csize = match z64 { [_, Just(v), _] -> v; _ -> csize0 }
  val local = match z64 { [_, _, Just(v)] -> v; _ -> local0 }
  if b.u32(local) != 0x04034b50 then throw("zip: invalid local header for " ++ name)
  val data-start = local + 30 + b.u16(local + 26) + b.u16(local + 28)
  val stored = b.subbytes(data-start, csize)
  if stored.length != csize then throw("zip: " ++ name ++ " is cut off")
  val encrypted = flags % 2 == 1
  if encrypted && password.is-empty then throw("zip: " ++ name ++ " is encrypted (a password is needed)")
  // decrypt: WinZip AES (method 99), or ZipCrypto
  val (packed, method, enc, check-crc) =
    if !encrypted then (stored, method0, No-encryption, True)
    elif method0 == 99 then match b.find-extra(extra, extra-len, 0x9901)
      Just(x) ->
        val version = b.u16(x)
        val strength = b.u8(x + 4)
        val e = match strength { 1 -> Aes128; 2 -> Aes192; _ -> Aes256 }
        (aes-decrypt(name, password, strength, stored), b.u16(x + 5), e, version == 1)
      Nothing -> throw("zip: " ++ name ++ " uses AES without its extra field")
    else
      if stored.length < 12 then throw("zip: " ++ name ++ " is cut off")
      val plain = prim-zipcrypto(password.bytes, stored, True)
      // the last header byte is the high byte of the CRC (or of the time with a data descriptor)
      val expected = if (flags / 8) % 2 == 1 then (dtime / 256) % 256 else (crc / 0x1000000) % 256
      if plain.u8(11) != expected then throw("zip: wrong password for " ++ name)
      (plain.subbytes(12), method0, Zip-crypto, True)
  val data = match method
    0 -> packed
    8 -> match try({ packed.inflate })
      Ok(d) -> d
      Error(err) -> throw("zip: " ++ name ++ ": " ++ (if encrypted then "wrong password or " else "") ++ err.message)
    _ -> throw("zip: " ++ name ++ " uses an unsupported compression method (" ++ method.show ++ ")")
  if data.length != usize then throw("zip: " ++ name ++ " has the wrong size")
  if check-crc && crc32(data) != crc then throw("zip: " ++ name ++ " has a wrong checksum" ++ (if encrypted then " (wrong password?)" else ""))
  val made-by-unix = b.u8(at + 5) == 3
  val mode = if made-by-unix then (attrs / 65536) % 0x1000 else 0
  Zip-entry(name, data, method == 8, mode, "", enc)

// Read one entry by name.
pub fun zip-find( b : bytes, entry-name : string, password : string = "" ) : exn maybe<zip-entry>
  zip-read(b, password).find(fn(e) e.name == entry-name)

// ----------------------------------------------------------------------------
// Writing
// ----------------------------------------------------------------------------

// 1980-01-01 00:00 in MS-DOS format: zip entries get a fixed time, so that
// the same entries always give the same archive (except for encryption salts).
val dos-time = 0
val dos-date = (0 * 512) + (1 * 32) + 1

// Write an archive with the entries, in order. The zip64 format is used when
// the archive needs it (65535 entries or more, or sizes or offsets of 4 GiB
// or more), or always with `zip64 = True`.
pub fun zip-write( entries : list<zip-entry>, zip64 : bool = False ) : <exn,ndet> bytes
  val (locals, centrals, total) = entries.foldl(([], [], 0)) fn((ls, cs, offset), e)
    val (local, central) = write-entry(e, offset, zip64)
    (Cons(local, ls), Cons(central, cs), offset + local.length)
  val body = locals.reverse.join
  val cd = centrals.reverse.join
  val n = entries.length
  val big = zip64 || n >= max16 || total >= max32 || cd.length >= max32
  val z64-end = if !big then bytes/empty else
    val rec = ints(le32(0x06064b50) ++ le64(44) ++ le16(45) ++ le16(45) ++ le32(0) ++ le32(0)
                   ++ le64(n) ++ le64(n) ++ le64(cd.length) ++ le64(body.length))
    val locator = ints(le32(0x07064b50) ++ le32(0) ++ le64(body.length + cd.length) ++ le32(1))
    rec ++ locator
  val eocd = ints(le32(0x06054b50) ++ le16(0) ++ le16(0)
                  ++ le16(if big then max16 else n) ++ le16(if big then max16 else n)
                  ++ le32(if big then max32 else cd.length) ++ le32(if big then max32 else body.length) ++ le16(0))
  body ++ cd ++ z64-end ++ eocd

// The local header with the data, and the central directory entry.
fun write-entry( e : zip-entry, offset : int, force64 : bool ) : <exn,ndet> (bytes, bytes)
  val name-bytes = e.name.bytes
  val crc = crc32(e.data)
  val deflated = if e.compress && !e.is-directory then e.data.deflate else e.data
  val (method, packed) = if e.compress && !e.is-directory && deflated.length < e.data.length then (8, deflated) else (0, e.data)
  val enc = if e.password.is-empty || e.is-directory then No-encryption else e.encryption
  val (stored, stored-method, extra-aes, crc-field) = match enc
    No-encryption -> (packed, method, [], crc)
    Zip-crypto ->
      val header = random-bytes(11) ++ [(crc / 0x1000000) % 256].vector.bytes
      (prim-zipcrypto(e.password.bytes, header ++ packed, False), method, [], crc)
    _ ->
      // AE-2: the CRC is not stored (the authentication code protects the data)
      val aes = le16(0x9901) ++ le16(7) ++ le16(2) ++ [65, 69] ++ [enc.aes-strength] ++ le16(method)
      (aes-encrypt(e.password, enc, packed), 99, aes, 0)
  val big = force64 || stored.length >= max32 || e.data.length >= max32 || offset >= max32
  val utf8-flag = if e.name.list.any(fn(c) c.int >= 0x80) then 0x800 else 0
  val enc-flag = match enc { No-encryption -> 0; _ -> 1 }
  val version = if big then 45 elif stored-method == 99 then 51 else 20
  val local-extra = (if big then le16(0x0001) ++ le16(16) ++ le64(e.data.length) ++ le64(stored.length) else []) ++ extra-aes
  val central-extra = (if big then le16(0x0001) ++ le16(24) ++ le64(e.data.length) ++ le64(stored.length) ++ le64(offset) else []) ++ extra-aes
  val common = le16(utf8-flag + enc-flag) ++ le16(stored-method) ++ le16(dos-time) ++ le16(dos-date) ++ le32(crc-field)
               ++ le32(if big then max32 else stored.length) ++ le32(if big then max32 else e.data.length) ++ le16(name-bytes.length)
  val local = ints(le32(0x04034b50) ++ le16(version) ++ common ++ le16(local-extra.length)) ++ name-bytes ++ ints(local-extra) ++ stored
  val mode = if e.unix-mode != 0 then e.unix-mode elif e.is-directory then 0x1ED else 0x1A4
  val kind = if e.is-directory then 0x4000 else 0x8000
  val ext-attrs = (kind + mode) * 65536 + (if e.is-directory then 0x10 else 0)
  val central = ints(le32(0x02014b50) ++ [version, 3] ++ le16(version) ++ common ++ le16(central-extra.length) ++ le16(0) ++ le16(0) ++ le16(0)
                     ++ le32(ext-attrs) ++ le32(if big then max32 else offset)) ++ name-bytes ++ ints(central-extra)
  (local, central)
