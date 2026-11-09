// Effect handlers (try, finally) inside parallel tasks. These used to corrupt
// memory: values created at startup (string literals, top-level values, the
// empty evidence vector) had non-atomic reference counts but are shared by
// all threads.
import std/os/sync

val greeting = "hello from a top-level value"
val numbers = list(1, 100)

fun work( k : int ) : int
  var n := 0
  for(1, 20000) fn(i)
    with finally { n := n + 1 }
    match try({ if i % 97 == 0 then throw("x" ++ i.show) else i })
      Ok(_) -> ()
      Error(e) -> if e.message.count < 2 then n := n - 1000
  n + k + greeting.count + numbers.sum

fun main()
  println(list(1, 8).map(fn(k) spawn { work(k) }).map(join))
  // a mutex is released when the action raises an exception
  val m = mutex()
  val count = atomic(0)
  list(1, 4).map(fn(_) spawn {
    for(1, 1000) fn(i)
      match try({ m.with-lock { if i % 10 == 0 then throw("boom") else count.add(1) } })
        _ -> ()
  }).foreach(join)
  println(count.load)
