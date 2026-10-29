import std/data/deque
import std/data/heap
import std/num/random

fun main()
  val d = [1,2,3].deque
  println(d)
  println((d.front, d.back, d.length, d.at(1)))
  println(d.push-front(0).push-back(4))
  println(d.pop-front.map(fn((x,r)) (x, r.list)))
  println(d.pop-back.map(fn((x,r)) (x, r.list)))
  println((d.reverse, d.map(fn(x) x * 10), d.foldl(0, fn(a,x) a + x)))
  // queue usage: push-back many, pop-front all
  val q = list(1,10000).foldl(deque/empty(), fn(acc, i) acc.push-back(i))
  println((q.length, q.front, q.back, q.at(5000)))
  var cur := q
  var total := 0
  while { !cur.is-empty }
    match cur.pop-front
      Just((x, rest)) ->
        total := total + x
        cur := rest
      Nothing -> ()
  println(total)
  // mixed random operations vs list model
  val ok = pseudo-random(7) fn()
    var dq := deque/empty()
    var model := []
    var good := True
    for(1, 2000) fn(i)
      match random-int() % 4
        0 -> { dq := dq.push-front(i); model := Cons(i, model) }
        1 -> { dq := dq.push-back(i); model := model ++ [i] }
        2 -> match dq.pop-front
               Just((_, r)) -> { dq := r; model := model.drop(1) }
               Nothing -> ()
        _ -> match dq.pop-back
               Just((_, r)) -> { dq := r; model := model.take(model.length - 1) }
               Nothing -> ()
      if dq.list != model then good := False
    good
  println(ok)
  // heaps
  val h = [5,1,4,1,3].heap
  println(h)
  println((h.min, h.length, h.take(3)))
  println(h.pop-min.map(fn((x,r)) (x, r.list)))
  println(merge(h, [0,9].heap).list)
  val maxh = [5,1,4].heap(?cmp=fn(a : int, b : int) cmp(b,a))
  println(maxh.list(?cmp=fn(a : int, b : int) cmp(b,a)))
  val xs = pseudo-random(99, { list(1,5000).map(fn(_) random-int() % 100000) })
  println(xs.heap.list == xs.sort)
  // heap of tuples (priority, name)
  println([(3,"c"),(1,"a"),(2,"b")].heap.take(2))
