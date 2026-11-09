// std/os/sync: threads, atomics, shared cells, mutexes and channels
import std/os/sync

fun main()
  val n = 20000
  // atomic counters from several threads
  val hits = atomic(0)
  val ws = list(1, 4).map(fn(_) spawn { for(1, n) fn(_) { hits.add(1); () } })
  ws.foreach(join)
  println(hits.load)
  // compare-and-swap loops
  val c = atomic(0)
  fun cas-increment() : <ndet,div> ()
    val old = c.load
    if !c.compare-exchange(old, old + 1) then cas-increment()
  list(1, 4).map(fn(_) spawn { for(1, n) fn(_) cas-increment() }).foreach(join)
  println(c.load)
  println((c.exchange(5), c.fetch-add(2), c.load))
  // a read-modify-write under a mutex
  val m = mutex()
  val total = shared(0)
  list(1, 4).map(fn(_) spawn { for(1, n) fn(_) m.with-lock { total.write(total.read + 1) } }).foreach(join)
  println(total.read)
  // atomic updates of a shared value
  val names = shared([])
  list(1, 8).map(fn(i) spawn { names.update(fn(xs) Cons(i, xs)); () }).foreach(join)
  println((names.read.length, names.read.sum))
  // results from futures
  println(list(1, 6).map(fn(i) spawn { list(1, i * 1000).sum }).map(join))
  // producers and a consumer
  val ch = channel()
  val producers = list(1, 4).map fn(p)
    spawn
      for(1, 100) fn(i) ch.send(p * 1000 + i)
  val received = list(1, 400).map(fn(_) ch.receive)
  producers.foreach(join)
  println((received.length, received.sum, ch.try-receive, ch.count))
  ch.send("x".count)
  println(ch.try-receive)
  // a bounded channel: the producer waits while it is full
  val small = channel(2)
  println((small.try-send(1), small.try-send(2), small.try-send(3), small.count))
  println((small.receive, small.receive, small.try-receive))
  if has-threads() then
    val most = atomic(0)
    val producer = spawn
      for(1, 200) fn(i)
        small.send(i)
        val queued = small.count
        if queued > most.load then most.store(queued)
    val got = list(1, 200).map(fn(_) small.receive)
    producer.join
    println((got == list(1, 200), most.load <= 2))
  else println((True, True))
