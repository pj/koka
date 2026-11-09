// std/data/array: mutable growable arrays
import std/data/array
import std/time/timer
import std/time/duration
import std/num/ddouble

fun squares( n : int ) : exn list<int>
  run
    val a = array()
    for(1, n) fn(i) a.push(i * i)
    a.set(0, 100)
    a.list

fun sieve( n : int ) : <exn,div> int
  run
    val marks = array-fill(n + 1, True)
    marks.set(0, False)
    marks.set(1, False)
    for(2, n) fn(i)
      if marks.get(i) then
        var j := i * i
        while { j <= n }
          marks.set(j, False)
          j := j + i
    marks.foldl(0, fn(c, b) if b then c + 1 else c)

fun main()
  println(squares(5))
  println(sieve(100000))
  run
    val a = [5, 3, 8, 1].array
    println((a.length, a[2], a.at(10), a.last, a.is-empty))
    a.push(9)
    a.insert(0, 0)
    a.insert(6, 7)
    println(a.show)
    println((a.remove-at(1), a.pop, a.show))
    a.swap(0, 1)
    a.modify(2, fn(x) x * 10)
    a.reverse
    println(a.show)
    a.sort
    println((a.show, a.find-index(fn(x) x > 4), a.slice(1, 2).list, a.slice(3).list, a.vector.length))
    val snapshot = a.vector
    a.map-in-place(fn(x) x + 1)
    println((snapshot.list, a.list))
    println((try({ a.get(99) }).is-error, try({ a.set(-1, 0) }).is-error, try({ a.insert(99, 0) }).is-error))
    a.clear
    println((a.length, a.pop))
    a.extend([1, 2, 3])
    println(a.foldl(0, (+)))
  // pushing many elements takes linear time (in place)
  val t0 = ticks()
  val total = run
    val big = array()
    for(1, 1000000) fn(i) big.push(i)
    for(0, 999999) fn(i) big.set(i, big.get(i) * 2)
    big.foldl(0, (+))
  println((total, (ticks() - t0) < 5.seconds))
