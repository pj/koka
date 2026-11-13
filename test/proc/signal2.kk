// std/async/os/signal: handling signals every time they arrive (with-signals)
import std/async
import std/async/os/signal
import std/time/duration

fun raise-later( sigs : list<signal> ) : <async,exn> ()
  sigs.foreach fn(s)
    wait(20.milli-seconds)
    raise-signal(s)

fun main()
  // signals that arrive while nobody waits are queued, in order; SIGINT does
  // not terminate the process anywhere in the scope
  val got = with-signals([SIGUSR1, SIGUSR2, SIGINT]) fn(sigs)
    raise-later([SIGUSR1, SIGUSR2, SIGINT, SIGUSR1])
    wait(50.milli-seconds)
    val queued = [sigs.next, sigs.next, sigs.next, sigs.next]
    (queued, sigs.try-next)
  println(got)
  // a reload loop that stops on SIGTERM
  val reloads = with-signals([SIGHUP, SIGTERM]) fn(sigs)
    val (n, _) = interleaved({
      var count := 0
      while { sigs.next != SIGTERM } { count := count + 1 }
      count
    }, { raise-later([SIGHUP, SIGHUP, SIGHUP, SIGTERM]) })
    n
  println(("reloads", reloads))
  // after the scope, waiting for a signal still works
  val (again, _) = interleaved({ wait-signal([SIGUSR2]) }, { raise-later([SIGUSR2]) })
  println(again)
  // handling can be cancelled
  println(timeout(50.milli-seconds, { with-signals([SIGUSR1]) fn(sigs) sigs.next }).is-nothing)
