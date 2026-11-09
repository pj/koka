// UDP multicast over the loopback interface
import std/async
import std/async/os/udp
import std/time/duration

val group = "239.255.42.99"

fun main()
  with rx = udp-bind("0.0.0.0", 0)
  val port = rx.local-port
  rx.join-multicast(group, "127.0.0.1")
  with tx = udp-bind("127.0.0.1", 0)
  tx.set-multicast-interface("127.0.0.1")
  tx.set-multicast-ttl(1)
  tx.set-multicast-loop(True)
  tx.send-to("to the group".bytes, group, port)
  match timeout(2.seconds, { rx.receive-from })
    Just((data, ip, _)) -> println((data.string, ip))
    Nothing -> println("no multicast datagram (is multicast routed on this machine?)")
  // after leaving the group nothing arrives
  rx.leave-multicast(group, "127.0.0.1")
  tx.send-to("too late".bytes, group, port)
  println(timeout(300.milli-seconds, { rx.receive-from }).is-nothing)
  // errors are reported
  println(try({ rx.join-multicast("10.0.0.1") }).is-error)
