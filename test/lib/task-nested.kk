// Deeply nested parallel tasks (work stealing). With one shared queue, a
// thread waiting for a promise ran unrelated outer tasks on its own stack,
// which overflowed for deep nesting; and promises were corrupted when they
// were completed by another thread than the one that created them.
import std/os/sync
import std/core/undiv

fun fib( n : int ) : int
  if n < 2 then n else fib(pretend-decreasing(n - 1)) + fib(pretend-decreasing(n - 2))

fun pfib( n : int, depth : int ) : <ndet,div> int
  if depth <= 0 || n < 2 then fib(n)
  else
    val a = spawn { pfib(pretend-decreasing(n - 1), depth - 1) }
    val b = pfib(pretend-decreasing(n - 2), depth - 1)
    a.join + b

fun main()
  println(pfib(30, 20))
  println(list(1, 20).map(fn(_) pfib(24, 12)).all(fn(r) r == 46368))
