import std/data/map
import std/num/random

// model: association list sorted by key
fun model-insert( xs : list<(int,int)>, k : int, v : int ) : list<(int,int)>
  Cons((k,v), xs.filter(fn((kk,_)) kk != k)).sort-on(tuple2/fst)

fun model-remove( xs : list<(int,int)>, k : int ) : list<(int,int)>
  xs.filter(fn((kk,_)) kk != k)

fun same( m : map<int,int>, xs : list<(int,int)> ) : bool
  m.is-valid && m.length == xs.length && m.list.map(tuple2/fst) == xs.map(tuple2/fst) && m.list.map(tuple2/snd) == xs.map(tuple2/snd)

fun random-ops( n : int ) : random (map<int,int>, list<(int,int)>, bool)
  var m := map/empty()
  var xs := []
  var ok := True
  for(1, n) fn(i)
    val k = random-int() % 200
    if random-int() % 3 == 0 then
      m := m.remove(k)
      xs := model-remove(xs, k)
    else
      m := m.insert(k, i)
      xs := model-insert(xs, k, i)
    if !same(m, xs) then ok := False
  (m, xs, ok)

fun main()
  val m = [(3,"c"),(1,"a"),(2,"b")].from-list
  println(m)
  println((m.length, m.lookup(2), m.lookup(5), m.contains(3)))
  println(m.insert(4,"d").remove(1))
  println((m.keys, m.values))
  println((m.min, m.max))
  println((m.lookup-lt(2), m.lookup-le(2), m.lookup-gt(2), m.lookup-ge(4)))
  println((m.elem-at(0), m.elem-at(2), m.elem-at(3), m.index-of(3)))
  println(m.map(fn(s) s ++ s))
  println(m.filter(fn(k,_) k != 2))
  println(m.alter(2, fn(_) Nothing).alter(9, fn(_) Just("z")))
  println(m.update(1, fn(s) s ++ "!"))
  println(m.foldl("", fn(acc,k,v) acc ++ k.show ++ v))
  println(catch(fn(_) "missing", { m[1] }) ++ " " ++ catch(fn(_) "missing", { m[7] }))
  // word count with alter
  val counts = "the cat and the hat and the bat".split(" ")
                 .foldl(map/empty(), fn(acc, w) acc.alter(w, fn(mb) Just(mb.default(0) + 1)))
  println(counts)
  // set operations
  val a = list(1,10).map(fn(i) (i, i)).from-list
  val b = list(5,15).map(fn(i) (i, i*10)).from-list
  println(union(a, b).keys)
  println(union-with(a, b, fn(x,y) x + y).values)
  println(intersection(a, b))
  println(difference(a, b))
  println((a.split(5).fst.keys, a.split(5).snd.keys))
  println((a == a, a == b, a.is-submap-of(union(a,b))))
  val (pe, po) = a.partition(fn(k,_) k.is-even)
  println((pe.keys, po.keys))
  // randomized model test
  val (big, model, ok) = pseudo-random(1234, { random-ops(3000) })
  println((ok, big.length == model.length, big.is-valid))
  // large ascending insert stays balanced; union/intersection/difference agree with model
  val asc = list(1,20000).foldl(map/empty(), fn(acc, i) acc.insert(i, i))
  println((asc.is-valid, asc.length, asc.elem-at(9999)))
  val evens = list(0,20000).filter(is-even).map(fn(i) (i, i)).from-list
  val u = union(asc, evens)
  val n = intersection(asc, evens)
  val d = difference(asc, evens)
  println((u.is-valid, u.length, n.is-valid))
  println((n.length, d.is-valid, d.length))
