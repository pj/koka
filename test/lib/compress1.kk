// std/compress: deflate, zlib and gzip, at once and as streams
import std/compress
import std/os/fs
import std/os/process

fun main()
  val text = "hello hello hello hello, compressed world! ".repeat(100)
  val data = text.bytes
  // round trips in every format
  [Deflate, Zlib, Gzip].foreach fn(f)
    val packed = data.compress(f)
    println((packed.length < data.length / 10, packed.decompress(f).string == text))
  println(data.gzip.decompress.string == text)              // Auto detects gzip
  println(data.compress(Zlib).decompress.string == text)    // and zlib
  println(data.deflate(level = 0).length > data.length)     // level 0 stores
  println(data.deflate(9).inflate.string == text)
  println(bytes/empty.gzip.gunzip.length)

  // the formats are recognizable
  val gz = data.gzip
  println((gz[0], gz[1]))          // gzip magic 0x1f 0x8b
  println(data.compress(Zlib)[0])  // zlib header 0x78

  // two gzip members after another decompress to both parts
  println(("first ".bytes.gzip ++ "second".bytes.gzip).gunzip.string)

  // errors
  println(try({ "not compressed".bytes.gunzip }).is-error)
  println(match try({ gz.subbytes(0, gz.length - 10).gunzip }) { Error(e) -> e.message; Ok(_) -> "ok" })
  println(try({ data.compress(Zlib).inflate }).is-error)

  // checksums
  println(crc32("The quick brown fox jumps over the lazy dog".bytes).show-hex)
  println(crc32("dog".bytes, crc32("The quick brown fox jumps over the lazy ".bytes)).show-hex)
  println(adler32("Wikipedia".bytes).show-hex)
  println(adler32("pedia".bytes, adler32("Wiki".bytes)).show-hex)

  // streams, with chunks that split the compressed data anywhere
  val text-lines = range(1, 20000).map(fn(i) "line " ++ i.show).unlines
  val packed = text-lines.gzip.read-all
  println(packed.length < 100000)
  [1, 7, 4096].foreach fn(n)
    val back = packed.stream(n).gunzip.lines
    println((n, back.length, back.drop(19998).list))
  println(text-lines.compress(Deflate, 1).decompress(Deflate).read-text == text-lines.read-text)
  println(match try({ packed.subbytes(0, 1000).stream.gunzip.read-all }) { Error(e) -> e.message; Ok(_) -> "ok" })

  // interoperability with the gzip program, through files
  with-temp-dir fn(dir)
    val f = dir / "lines.txt.gz"
    write-stream(f, text-lines.gzip)
    println(run-output("gzip", ["-dc", f.string]).count)
    val g = dir / "other.gz"
    println(run("sh", ["-c", "printf 'made by gzip\\n' | gzip > " ++ g.string]).exit-code)
    with-file(g, Read) fn(h)
      println(h.stream.gunzip.read-text.show)
