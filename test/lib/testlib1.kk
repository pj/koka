import std/test
import std/log
import std/text/format

fun sample-tests() : testing ()
  group("arith")
    test("add")
      expect-eq(1 + 1, 2)
    test("wrong")
      expect-eq(2 * 3, 7)
    test("throws")
      expect-throws({ throw("boom") })
  group("lists")
    test("sort is idempotent")
      check-property("sort idempotent", gen-list(gen-int(0, 50))) fn(xs)
        xs.sort.sort == xs.sort
    test("bad property")
      check-property("all small", gen-int(0, 100), fn(x) x < 90)
    test("expect")
      expect(False, "custom message")

fun work( n : int ) : log int
  log-debug("starting", [("n", n.show)])
  if n > 2 then log-warn("large n", [("n", n.show), ("note", "two words")])
  log-info("done")
  n * 2

fun main()
  // test framework (results with locations stripped for stable output)
  val s = collect-tests(sample-tests)
  println("passed: " ++ s.passed.show)
  s.failed.foreach fn((name, msg))
    val m = match msg.find(": ") { Just(sl) -> sl.after.string; Nothing -> msg }
    println("failed: " ++ name ++ " -- " ++ m)
  // logging
  val (r, entries) = log-collect { work(3) }
  println(r)
  entries.foreach(fn(e) println(e.show))
  println(log-ignore { work(5) })
  println(log-collect({ with-log-fields([("req","42")], { work(1) }) }).snd.map(fn(e) e.show))
  // format
  println(format("{} is {} years old", ["ann", 30.show]))
  println(format("[{:>6}] [{:<6}] [{:^6}] [{1}{0}]", ["a","b","c"]))
  println(format("{:08} {:*^9} {{literal}}", [42.show, "mid"]))
  println(catch(fn(e) e.message, { format("{} {}", ["only one"]) }))
  println(catch(fn(e) e.message, { format("{oops}", ["x"]) }))
  println(pad("x", 3, '.', '>'))
