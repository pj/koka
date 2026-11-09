// std/compress/brotli: bytes and streams
import std/compress/brotli

fun main()
  val text = "hello brotli! ".repeat(200)
  val data = text.bytes
  val packed = data.brotli
  println((data.length, packed.length < 100))
  println(packed.unbrotli.string == text)
  println(data.brotli(0).unbrotli.string == text)
  println(data.brotli(5, 16).unbrotli.string == text)
  println(bytes/empty.brotli.unbrotli.length)
  // streams, with chunks that split the data anywhere
  [1, 7, 4096].foreach fn(n)
    println((n, packed.stream(n).unbrotli.read-all.string == text))
  println(data.stream(10).brotli.read-all.unbrotli.string == text)
  // errors
  println(try({ "not brotli at all".bytes.unbrotli }).is-error)
  println(match try({ packed.subbytes(0, packed.length - 3).unbrotli }) { Error(e) -> e.message; Ok(_) -> "ok" })
  println(match try({ packed.subbytes(0, packed.length - 3).stream.unbrotli.read-all }) { Error(e) -> e.message; Ok(_) -> "ok" })
