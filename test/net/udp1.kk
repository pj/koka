// UDP sockets
import std/async
import std/async/os/udp
import std/time/duration

fun main()
  with a = udp-bind("127.0.0.1", 0)
  with b = udp-bind("127.0.0.1", 0)
  val bport = b.local-port
  // a datagram, and a reply to the sender's address
  a.send-to("ping".bytes, "127.0.0.1", bport)
  val (data, ip, port) = b.receive-from
  println((data.string, ip, port == a.local-port))
  b.send-to("pong".bytes, ip, port)
  println(a.receive-from.fst.string)
  // datagram boundaries are kept, also for empty and large datagrams
  a.send-to("one".bytes, "127.0.0.1", bport)
  a.send-to(bytes/empty, "127.0.0.1", bport)
  a.send-to("x".repeat(8000).bytes, "localhost", bport)   // host names are resolved
  println([b.receive-from, b.receive-from, b.receive-from].map(fn((d, _, _)) d.length))
  // a receive can be canceled; later datagrams are still received
  println(timeout(50.milli-seconds) { b.receive-from.fst.string })
  a.send-to("after timeout".bytes, "127.0.0.1", bport)
  println(b.receive-from.fst.string)
  // concurrent receive and send
  val (got, _) = interleaved({ b.receive-from.fst.string }, { a.send-to("concurrent".bytes, "127.0.0.1", bport) })
  println(got)
  // errors
  println(catch(fn(e) "send failed", { a.send-to("x".bytes, "not an ip:", 1); "sent" }))
  println(catch(fn(e) "bind failed", { val _ = udp-bind("127.0.0.1", bport); "bound" }))
  // closing the socket ends a pending receive
  val c = udp-bind("127.0.0.1", 0)
  val (r, _) = interleaved({ catch(fn(_) "receive ended", { c.receive-from.fst.string }) }, { c.close })
  println(r)
