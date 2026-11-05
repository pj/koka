// std/core/seq: lazy sequences and generators
import std/core/seq

fun fib() : seq<e,int>
  generate
    var a := 0
    var b := 1
    while { True }
      yield(a)
      val c = a + b
      a := b
      b := c

fun naturals-below( n : int ) : seq<e,int>
  generate
    for(0, n - 1) fn(i) yield(i)

fun primes() : seq<e,int>
  count-from(2).filter(fn(n) range(2, n - 1).all(fn(d) n % d != 0))

fun main()
  // construction
  println(count-from(1).map(fn(i) i * i).filter(is-odd).take(5).list)
  println(fib().take(12).list)
  println(fib().show)
  println(range(1, 5).show)
  println(seq/empty().show(?show = int/show))
  println(once(42).list)
  println(cons(0, [1, 2].seq).list)
  println(unfold(10, fn(n) if n == 0 then Nothing else Just((n, n / 2))).list)
  println(iterate(1, fn(x) x * 3).take(6).list)
  println(repeat("ab").take(3).join("-"))
  println([1, 2, 3].seq.cycle.take(8).list)
  println(seq/empty().cycle.take(3).list.show(?show = int/show))
  println(vector([7, 8, 9]).seq.list)
  println("héllo".seq.map(fn(c) if c == 'l' then 'L' else c).string)
  println(Just(5).seq.list ++ Nothing.seq.list)
  println(naturals-below(5).list)

  // transformation
  println(range(1, 10).filter(is-even).list)
  println(range(1, 10).remove(is-even).list)
  println(range(1, 10).filter-map(fn(i) if i % 3 == 0 then Just(i * 10) else Nothing).list)
  println(count-from().drop(5).take(3).list)
  println(range(1, 10).take-while(fn(i) i < 4).list)
  println(range(1, 10).drop-while(fn(i) i < 8).list)
  println(count-from().step-by(4).take(4).list)
  println((range(1, 3) ++ range(10, 12)).list)
  println(range(1, 4).flat-map(fn(i) repeat(i).take(i)).list)
  println([range(1, 2), seq/empty(), range(3, 4)].seq.concat.list)
  println(zip(count-from(), "abc".seq).list.show)
  println(zip-with(range(1, 5), count-from(10), (+)).list)
  println(range(1, 5).scan(0, (+)).list)
  println(range(1, 7).chunk(3).list.show)
  println(range(1, 5).window(3).list.show)
  println(range(1, 2).window(3).list.show)
  println(range(1, 4).intersperse(0).list)
  println([1, 1, 2, 3, 3, 3, 1].seq.dedup.list)
  println("abc".seq.indexed(1).list.show)
  println("abc".seq.map-indexed(fn(i, c) c.show ++ i.show).join(" "))

  // consumption
  println(range(1, 100).sum)
  println(range(1, 100).length)
  println(primes().take(10).list)
  println(primes().at(99))
  println(count-from().find(fn(i) i * i > 50))
  println(count-from().any(fn(i) i > 1000))
  println(range(1, 10).all(fn(i) i < 10))
  println(range(1, 5).foldl("", fn(acc, i) acc ++ i.show))
  println(range(3, 9).last)
  println(([3, 1, 4, 1, 5].seq.minimum, [3, 1, 4, 1, 5].seq.maximum).show)
  println(seq/empty().head.map(int/show))
  println((range(1, 3).is-empty, [1].seq.drop(1).is-empty).show)
  val (front, back) = count-from().split-at(3)
  println(front.show ++ " " ++ back.take(2).list.show)
  match range(1, 3).uncons
    Just((x, rest)) -> println(x.show ++ " then " ++ rest.list.show)
    Nothing -> println("empty")
  range(1, 3).foreach-indexed fn(i, x)
    println(i.show ++ ": " ++ x.show)

  // laziness: only the demanded elements are computed
  var computed := 0
  val counted = count-from().map fn(i)
    computed := computed + 1
    i
  println(counted.filter(fn(i) i % 10 == 9).take(2).list.show ++ " computed " ++ computed.show)

  // generators run only up to the next yield
  val steps = ref([])
  fun step( name : string )
    steps := Cons(name, !steps)
  val gen = generate
    step("a")
    yield(1)
    step("b")
    yield(2)
    step("c")
  val first = gen.head
  println(first.show ++ " after " ++ (!steps).reverse.join(","))
  val all = gen.list
  println(all.show ++ " after " ++ (!steps).reverse.join(","))

  // generators can yield from other sequences
  val nested = generate
    yield(0)
    yield-all(range(1, 3))
    yield(99)
  println(nested.list)

  // generators can use other effects; each traversal runs them again
  val log = ref([])
  val logged = generate
    for(1, 3) fn(i)
      log := Cons(i, !log)
      yield(i * i)
  val pairs = logged.zip(logged.drop(1)).list
  println(pairs.show ++ " log " ++ (!log).reverse.show)

  // long sequences do not overflow the stack
  val big = 300000
  val g = generate
    for(1, big) fn(i) yield(i)
  println((g.foldl(0, fn(a, x) a + x), g.list.length, range(1, big).split-at(big / 2).fst.length))
  println((range(1, big).map(fn(i) i * 2).filter(fn(i) i % 3 == 0).length, count-from().filter(fn(i) i == big).head))
