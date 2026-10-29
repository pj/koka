import std/data/set
import std/data/imap
import std/data/dict

fun main()
  val s = [3,1,2,3,1].from-list
  println(s)
  println((s.length, s.contains(2), s.contains(9), s.min, s.max))
  println(s.insert(0).remove(3))
  val a = list(1,10).from-list
  val b = list(5,15).from-list
  println((union(a,b).length, intersection(a,b), difference(a,b)))
  println((a.is-subset-of(union(a,b)), b.is-subset-of(a), a.is-disjoint([20,21].from-list)))
  println(a.filter(is-even))
  println(a.map(fn(x) x / 3))
  println((a.foldl(0, fn(acc,x) acc + x), a.all(fn(x) x > 0), a.any(fn(x) x > 9)))
  println((a.lookup-gt(4), a.lookup-lt(1), a.elem-at(3), a.index-of(7)))
  println((a == list(1,10).reverse.from-list, a == b, cmp(a, b) == Lt))
  println(["pear","fig","apple","fig"].from-list)
  println(list(1,5000).reverse.from-list.is-valid)
  // imap / dict are aliases of map
  val im : imap<string> = [(2,"two"),(1,"one")].from-list
  println(im)
  val d : dict<int> = [("b",2),("a",1)].from-list
  println((d, d.lookup("a")))
