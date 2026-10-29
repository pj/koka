import std/async
import std/async/os/net
import std/time/duration

fun upper-echo( conn : tcp-socket ) : <async,exn> ()
  val data = conn.read-all
  conn.write-text(data.string.to-upper)

fun main()
  val server = tcp-listen("127.0.0.1", 0)
  val port = server.local-port
  println(port > 0)
  // server handles two connections, one after the other; clients run concurrently
  val (_, results) = interleaved({
    server.accept(upper-echo)   // the scoped `accept` closes the connection afterwards
    server.accept(upper-echo)
  }, {
    val r1 = tcp-connect("127.0.0.1", port) fn(c)
      c.write-text("hello ")
      c.write-text("world")
      c.shutdown-write
      c.read-all-text
    val r2 = tcp-connect("localhost", port) fn(c)
      c.write-text("second")
      c.shutdown-write
      c.read-all-text
    (r1, r2)
  })
  println(results)
  // large transfer (many chunks)
  val big = list(1, 20000).map(fn(i) i.show).join(",")
  val (_, echoed) = interleaved({
    with c = server.accept
    c.write-all(c.read-all)
  }, {
    with c = tcp-connect("127.0.0.1", port)
    c.write-text(big)
    c.shutdown-write
    c.read-all-text
  })
  println((echoed == big, echoed.count))
  server.close
  // connecting to a port nobody listens on fails
  println(catch(fn(e) "connect failed", { tcp-connect("127.0.0.1", port); "connected?" }))
  // a read can be canceled by a timeout
  val s2 = tcp-listen("127.0.0.1", 0)
  val p2 = s2.local-port
  val (_, timed) = interleaved({
    with c = s2.accept
    wait(300.milli-seconds)
  }, {
    with c = tcp-connect("127.0.0.1", p2)
    timeout(50.milli-seconds, { c.read.length })
  })
  println(timed)
  s2.close
  println(resolve-host("localhost").is-empty.not)
