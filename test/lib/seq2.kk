// std/core/seq: sequences from the std/data collections
import std/core/seq
import std/data/map
import std/data/set
import std/data/hashmap
import std/data/hashset
import std/data/deque
import std/data/heap

fun main()
  val m = map/from-list([(5, "five"), (1, "one"), (3, "three"), (9, "nine"), (7, "seven")])
  println(m.seq.list.show)
  println(m.seq.map(snd).take(2).list)
  println(m.seq-from(4).list.show)
  println(m.seq-from(10).list.show)
  println(map/empty().seq.list.show(?show = fn((k : int, v : string)) k.show ++ v))
  // a large map traverses lazily without building a list
  val big = list(1, 100000).foldl(map/empty(), fn(acc, i) acc.insert(i, i * i))
  println(big.seq.filter(fn((k, _)) k % 25000 == 0).map(snd).list)
  println(big.seq-from(99998).list.show)

  val s = set/from-list([4, 2, 8, 6, 2])
  println(s.seq.list)
  println(s.seq-from(5).list)

  val hm = hashmap/from-list([("a", 1), ("b", 2), ("c", 3)])
  println(hm.seq.list.map(snd).sort)
  val hs = hashset/from-list(["x", "y", "x"])
  println(hs.seq.list.sort)

  val d = deque/from-list([2, 3]).push-front(1).push-back(4).push-back(5)
  println(d.seq.list)
  println(d.seq.take(2).list)

  val h = heap/from-list([5, 3, 9, 1, 7])
  println(h.seq.list)
  println(h.seq.take(2).list)
