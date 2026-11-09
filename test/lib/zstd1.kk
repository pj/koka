// std/compress/zstd: bytes and streams
import std/compress/zstd

fun main()
  val text = "hello zstd! ".repeat(200)
  val data = text.bytes
  val packed = data.zstd
  println((data.length, packed.length < 100))
  println((packed[0], packed[1], packed[2], packed[3]))   // magic 28 b5 2f fd
  println(packed.unzstd.string == text)
  println(data.zstd(19).unzstd.string == text)
  println(data.zstd(-5).unzstd.string == text)
  println(bytes/empty.zstd.unzstd.length)
  // two frames after another decompress to both parts
  println(("first ".bytes.zstd ++ "second".bytes.zstd).unzstd.string)
  // a skippable frame (magic 0x184D2A5?) in front is ignored
  val skip = [0x50, 0x2a, 0x4d, 0x18, 2, 0, 0, 0, 7, 7].vector.bytes
  println((skip ++ "after a skippable frame".bytes.zstd).unzstd.string)
  println(try({ bytes/empty.unzstd.length }).is-error)
  // streams, with chunks that split the data anywhere
  [1, 7, 4096].foreach fn(n)
    println((n, packed.stream(n).unzstd.read-all.string == text))
  println(data.stream(10).zstd.read-all.unzstd.string == text)
  val big = list(1, 20000).map(fn(i) "line " ++ i.show ++ "\n").join.bytes
  println(big.zstd.stream(1000).unzstd.read-all.length == big.length)
  // errors
  println(try({ "not zstd at all".bytes.unzstd }).is-error)
  println(match try({ packed.subbytes(0, packed.length - 3).unzstd }) { Error(e) -> e.message; Ok(_) -> "ok" })
  println(match try({ packed.subbytes(0, packed.length - 3).stream.unzstd.read-all }) { Error(e) -> e.message; Ok(_) -> "ok" })
