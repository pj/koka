import std/num/random

struct person(name : string, age : int)

fun main()
  println([3,1,2].sort)
  println([5,4,3,2,1].sort)
  println([1,2,3,4,5].sort)
  println(([] : list<int>).sort)
  println([42].sort)
  println(["pear","apple","fig","banana"].sort)
  println([3,1,2].sort-desc)
  println([3,1,2].sort-by(fn(x,y) cmp(y,x)))
  println(["bb","a","ccc",""].sort-on(fn(s : string) s.count))
  // stability: equal ages keep input order
  val ps = [Person("ann",30),Person("bob",25),Person("cat",30),Person("dan",25),Person("eve",20)]
  println(ps.sort-on(fn(p) p.age).map(fn(p) p.name))
  println([1,2,2,3].is-sorted.show ++ " " ++ [2,1].is-sorted.show)
  println(merge([1,3,5],[2,4,6]))
  println([1,1,2,3,3,3,1].dedup)
  println([1,1,2,3,3].group)
  println(vector([3,1,2]).sort.list)
  // larger randomized check against insertion via is-sorted and length/sum
  val xs = pseudo-random(42, fn() list(1,2000).map(fn(_) random-int() % 1000))
  val ys = xs.sort
  println((ys.is-sorted, ys.length == xs.length, ys.sum == xs.sum))
  println(list(1,100000).reverse.sort.take(3))
