// The HAMT against std/data/map under random inserts and removes, with
// hashes that collide completely or share long prefixes.
import std/data/hashmap
import std/data/map
import std/num/random
import std/core/seq

fun check( name : string, ops : list<(bool, int)>, ?hash : int -> int ) : <console,div> ()
  var hm := hashmap/empty()
  var m := map/empty()
  ops.foreach fn((ins, k))
    if ins then
      hm := hm.insert(k, k * 2)
      m := m.insert(k, k * 2)
    else
      hm := hm.remove(k)
      m := m.remove(k)
  val ok = hm.length == m.length &&
           hm.list.sort-on(tuple2/fst) == m.list &&
           list(0, 300).all(fn(k) hm.lookup(k) == m.lookup(k))
  val evens = hm.filter(fn(k, _) k.is-even)
  val ok2 = evens.length == m.filter(fn(k, _) k.is-even).length &&
            list(0, 300).all(fn(k) evens.lookup(k) == (if k.is-even then m.lookup(k) else Nothing))
  // removing everything gives the empty map
  val gone = hm.keys.foldl(hm, fn(acc, k) acc.remove(k))
  val ok3 = gone.length == 0 && gone.list.is-nil && gone == hashmap/empty()
  val ok4 = hm.seq.foldl(0, fn(n, _) n + 1) == hm.length && hm.map(fn(v) v + 1).foldl(0, fn(acc, _, v) acc + v) == m.foldl(0, fn(acc, _, v) acc + v) + m.length
  println(name ++ ": " ++ [ok, ok2, ok3, ok4].show ++ " " ++ hm.length.show)

fun main()
  val ops = pseudo-random(42)
    list(1, 4000).map(fn(_) (random-int() % 3 != 0, random-int() % 300))
  check("normal", ops)
  check("collide", ops, ?hash = fn(k) k % 3)                  // full collisions
  check("prefix", ops, ?hash = fn(k) (k % 5) * 0x1000_0000)   // equal low bits
  check("top", ops, ?hash = fn(k) 0xFFFF_FFFF - k % 7)        // high bits set
