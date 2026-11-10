// Diagnostics for platform differences (run in CI on Windows): crc32 of
// short byte values and slices, and the `zip1` entry that fails there.
import std/compress
import std/compress/zip

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
