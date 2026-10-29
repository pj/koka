fun main()
  val b = "hello world".bytes
  println((b.length, b.subbytes(0, 5).string, b.subbytes(6).string, b.subbytes(6).length))
  println(("ab".bytes ++ "cd".bytes).string)
  println((b.subbytes(11).length, b.subbytes(3,2).string))
  val e = bytes/empty ++ "xyz".bytes
  println((e.length, e.string))
