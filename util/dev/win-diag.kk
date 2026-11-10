// Diagnostics for platform differences (run in CI on Windows): crc32 of
// short byte values and slices, and the `zip1` entry that fails there.
import std/compress
import std/compress/zip
import std/num/int64

fun main()
  val ok = "ok".bytes
  println(("literal", ok.list.map(show), ok.length, crc32(ok).show-hex))
  val big = "xxxxok-and-more".bytes
  val sl = big.subbytes(4, 2)
  println(("slice", sl.list.map(show), sl.length, crc32(sl).show-hex))
  for(1, 9) fn(n)
    val s = big.subbytes(0, n)
    println((n, crc32(s).show-hex, crc32(s.list.vector.bytes).show-hex))
  val a = zip-write([zip-file("ok.txt", ok), zip-file("ünïcode.txt", "ok".bytes)])
  println(a.list.map(fn(x) x.show-hex(2, False)).join(" "))
  println(catch(fn(e) e.message, { zip-read(a).map(fn(e) e.name ++ ":" ++ e.data.length.show).join(",") }))
  // the archive of test/lib/zip1.kk
  val text = "hello zip world\n".repeat(100)
  val archive = zip-write([zip-file("hello.txt", text.bytes), zip-file("docs/", bytes/empty),
                           zip-file("docs/raw.bin", list(0, 255).vector.bytes, compress = False),
                           zip-file("ünïcode.txt", "ok".bytes), Zip-entry("run.sh", "echo hi".bytes, unix-mode = 0x1ED)])
  println(archive.list.map(fn(x) x.show-hex(2, False)).join(" "))
  println(catch(fn(e) e.message, { zip-read(archive).map(fn(e) e.name ++ ":" ++ e.data.length.show).join(",") }))
  // which entry sizes fail? (stored, since tiny data does not deflate)
  for(1, 9) fn(n)
    val d = "abcdefghij".bytes.subbytes(0, n)
    val z = zip-write([zip-file("f", d)])
    println((n, catch(fn(e) e.message, { zip-read(z).map(fn(e) e.data.list.map(show).join(".")).join(",") })))
  // the reader's steps by hand: the data of ok.txt starts at 36
  val s = a.subbytes(36, 2)
  println(("by hand", s.list.map(show), s.length, crc32(s).show-hex, a.subbytes(14, 4).list.map(show)))
  // reading a fresh copy of the archive
  val a2 = a.list.vector.bytes
  println(catch(fn(e) e.message, { zip-read(a2).map(fn(e) e.name ++ ":" ++ e.data.length.show).join(",") }))
  // integer arithmetic around 2^30..2^31 (from runtime values, so nothing is folded)
  val two = ok.length
  val x = two * 0x3CEE                     // 0x79DC
  val m1 = x * 65536                       // 0x79DC0000
  val m2 = m1 + 0xDD47                     // 0x79DCDD47
  val c = crc32(ok)
  println(("mul", m1.show-hex, m1 == 0x79DC0000))
  println(("add", m2.show-hex, m2 == 0x79DCDD47))
  println(("crc", c.show-hex, c == 0x79DCDD47, c == m2, m2 == c))
  println(("cmp", c != m2, (c < m2, c > m2)))
  val b1 = (two / 2) * 0x40000000          // 2^30
  println(("2^30", b1.show-hex, b1 == 0x40000000, (b1 - 1).show-hex))
  println(("2^31", (b1 * 2).show-hex, (b1 * 2) == 0x80000000))
  println(("i64", c.int64.show, m2.int64.show, c.int64 == m2.int64))
