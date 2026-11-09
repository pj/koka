// Connected UDP sockets
import std/async
import std/async/os/udp
import std/time/duration

fun main()
  with a = udp-bind("127.0.0.1", 0)
  with b = udp-bind("127.0.0.1", 0)
  with c = udp-bind("127.0.0.1", 0)
  println(a.remote-address)
  a.connect("127.0.0.1", b.local-port)
  println(a.remote-address == ("127.0.0.1", b.local-port))
  a.send("to b".bytes)
  println(b.receive-from.fst.string)
  // a connected socket only receives from its peer
  c.send-to("from c".bytes, "127.0.0.1", a.local-port)
  b.send-to("from b".bytes, "127.0.0.1", a.local-port)
  println(a.receive-from.fst.string)
  println(timeout(200.milli-seconds, { a.receive-from }).is-nothing)
  // after disconnecting it can talk to anyone again
  a.disconnect
  println(a.remote-address)
  c.send-to("hello again".bytes, "127.0.0.1", a.local-port)
  println(a.receive-from.fst.string)
  // sending without a peer is an error
  println(try({ c.send("nobody".bytes) }).is-error)
  // a host name is resolved
  c.connect("localhost", b.local-port)
  c.send("by name".bytes)
  println(b.receive-from.fst.string)
