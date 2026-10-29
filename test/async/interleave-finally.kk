// When an enclosing `firstof` (or `timeout`) cancels a nested interleaving,
// the finalizers of the nested strands still run.
import std/async
import std/time/duration

fun main()
  // directly under firstof
  val r1 = firstof({ with finally { println("1: finalized") }; wait(10.seconds); "a" }) { wait(10.milli-seconds); "b" }
  println("1: " ++ r1)
  // in a nested interleaving
  val r2 = firstof({ interleaved({ with finally { println("2: finalized left") }; wait(10.seconds) },
                                 { with finally { println("2: finalized right") }; wait(10.seconds) }); "a" }) { wait(10.milli-seconds); "b" }
  println("2: " ++ r2)
  // a finalizer that awaits still completes
  val r3 = timeout(10.milli-seconds) {
    interleaved({ with finally { wait(1.milli-seconds); println("3: finalized after awaiting") }; wait(10.seconds) },
                { wait(10.seconds) })
  }
  println("3: " ++ r3.map(fn(_) "completed").default("timed out"))
  // two levels deep, under catch and mask (as in `std/async/os/net/serve`)
  val r4 = firstof({ interleaved({ interleaved({ mask<exn>{ catch(fn(_) (), { with finally { println("4: finalized") }; wait(10.seconds) }) } },
                                               { wait(10.seconds) }); () },
                                 { wait(10.seconds) }); "a" }) { wait(10.milli-seconds); "b" }
  println("4: " ++ r4)
