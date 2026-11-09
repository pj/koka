// std/os/sync: condition variables
import std/os/sync
import std/time/duration

// (C only: on JS, waiting for another thread raises a deadlock exception)
fun main()
  // a bounded queue between a producer (this thread) and a consumer
  val m = mutex()
  val not-empty = condition()
  val not-full = condition()
  val queue : shared<list<int>> = shared([])
  val consumer = spawn
    fun take(acc : int, n : int) : <ndet,div> int
      if n == 0 then acc else
        val x = m.with-lock
          not-empty.wait-until(m, { !queue.read.is-nil })
          match queue.read
            Cons(y, ys) -> { queue.write(ys); not-full.notify; y }
            Nil         -> 0
        take(acc + x, n - 1)
    take(0, 1000)
  for(1, 1000) fn(i)
    m.with-lock
      not-full.wait-until(m, { queue.read.length < 4 })
      queue.write(queue.read ++ [i])
      not-empty.notify
  println(consumer.join)
  // several waiters released at once
  val ready = shared(False)
  val go = condition()
  val waiters = list(1, 3).map fn(i)
    spawn { m.with-lock { go.wait-until(m, { ready.read }) }; i }
  m.with-lock { ready.write(True); go.notify-all }
  println(waiters.map(join).sum)
  // a timed wait that nobody notifies
  println(m.with-lock { go.wait-for(m, 20.milli-seconds) })
