// std/io/stream: buffered writing
import std/io/stream

fun main()
  var writes := []
  val n = buffered(fn(b) writes := Cons(b.length, writes), size = 1000) {
    list(1, 500).foreach(fn(i) put-text(i.show ++ "\n"))
    put-bytes(bytes/empty)
    42
  }
  // 1892 bytes in 500 small pieces: one write at 1000 or more, then the rest at the end
  println((n, writes.reverse, writes.sum))
  // flush-buffer writes out what is collected so far
  var parts := []
  buffered(fn(b) parts := Cons(b.string, parts)) {
    put-text("a"); put-text("b"); flush-buffer(); put-text("c")
  }
  println(parts.reverse)
  // nothing written: no call
  var calls := 0
  buffered(fn(_) calls := calls + 1) { () }
  println(calls)
