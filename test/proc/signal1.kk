// std/async/os/signal: waiting for signals
import std/async
import std/async/os/net
import std/async/os/http
import std/async/os/process
import std/async/os/signal
import std/time/duration

fun main()
  println((SIGINT.number, SIGTERM.number, all-numbered()))
  // a signal sent by this process
  val (got, _) = interleaved({ wait-signal([SIGUSR1, SIGUSR2]) }, { wait(50.milli-seconds); raise-signal(SIGUSR2) })
  println(got)
  // SIGINT does not terminate the process while it is waited for
  val (int, _) = interleaved({ wait-signal() }, { wait(50.milli-seconds); raise-signal(SIGINT) })
  println(int)
  // a signal sent by another process
  val (from-child, code) = interleaved({ wait-signal([SIGUSR1]) }, { run-process("sh", ["-c", "sleep 0.1; kill -USR1 $PPID"]).exit-code })
  println((from-child, code))
  // waiting can be cancelled
  println(timeout(100.milli-seconds, { wait-signal([SIGHUP]) }).is-nothing)
  // graceful shutdown of a server
  val server = tcp-listen("127.0.0.1", 0)
  val base = "http://127.0.0.1:" ++ server.local-port.show
  val (stopped, answer) = interleaved({
    firstof({ http-serve(server, fn(_) text-response(200, "up")); "never" }, { wait-signal([SIGTERM]).show })
  }, {
    val r = http-get(base ++ "/")
    raise-signal(SIGTERM)
    r.body-text
  })
  server.close
  println((answer, "stopped on " ++ stopped))

fun all-numbered() : bool
  [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2, SIGWINCH, SIGPIPE, SIGCHLD].all(fn(s) s.number > 0)
