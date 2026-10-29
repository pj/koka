import std/data/hashmap
import std/data/hashset
import std/num/random

struct point(x : int, y : int)

fun point/hash( p : point ) : int
  hash-combine(p.x.hash, p.y.hash)

fun point/(==)( p : point, q : point ) : bool
  p.x == q.x && p.y == q.y

fun main()
  val m = [("one",1),("two",2),("three",3)].hashmap
  println((m.length, m.lookup("two"), m.lookup("four"), m.contains("one")))
  println(m.insert("four",4).remove("one").list.sort-on(tuple2/fst))
  println(m.keys.sort)
  println(m.alter("two", fn(mb : maybe<int>) mb.map(fn(x) x * 10)).lookup("two"))
  println(m.filter(fn(_, v) v.is-odd).keys.sort)
  println((m == m, m == m.insert("one", 0), m.map(fn(v) v + 1).values.sort))
  // struct keys with a user-defined hash
  val pm = [(Point(1,2),"a"),(Point(2,1),"b")].hashmap
  println((pm.lookup(Point(2,1)), pm.lookup(Point(3,3)), pm.length))
  // many keys, including collisions in the low bits
  val big = list(1,20000).foldl(hashmap/empty(), fn(acc, i) acc.insert("k" ++ i.show, i))
  println((big.length, big.lookup("k12345"), big.foldl(0, fn(acc,_,v) acc + v)))
  val smaller = list(1,20000).filter(is-even).foldl(big, fn(acc, i) acc.remove("k" ++ i.show))
  println((smaller.length, smaller.lookup("k2"), smaller.lookup("k3")))
  // word count
  val wc = "a b a c b a".split(" ").foldl(hashmap/empty(), fn(acc, w) acc.insert-with(w, 1, fn(o : int, n : int) o + n))
  println(wc.list.sort-on(tuple2/fst))
  // hash sets
  val s = [3,1,2,3,1].hashset
  println((s.length, s.contains(2), s.contains(5), s.list.sort))
  val t = list(2,6).hashset
  println((union(s, t).list.sort, intersection(s, t).list.sort, difference(s, t).list.sort))
  println((s.is-subset-of(union(s,t)), s == [1,2,3].hashset))
