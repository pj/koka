import std/os/process
import std/os/io
import std/os/env
import std/os/path

fun main()
  val r = run("echo", ["hello", "two words"])
  println((r.exit-code, r.stdout, r.stderr, r.is-success))
  val r2 = run("sh", ["-c", "echo out; echo err >&2; exit 3"])
  println((r2.exit-code, r2.stdout, r2.stderr))
  val r3 = run("tr", ["a-z", "A-Z"], input="shout this\n")
  println(r3.stdout)
  // large input and output (more than a pipe buffer) must not deadlock
  val big = list(1,20000).map(fn(i) i.show).join("\n") ++ "\n"
  val r4 = run("cat", [], input=big)
  println((r4.stdout == big, r4.stdout.count))
  val r5 = run("sh", ["-c", "echo $KOKA_TEST_VAR"], env=[("KOKA_TEST_VAR", "from-env")])
  println(r5.stdout)
  val r6 = run("pwd", [], cwd="/usr".path)
  println(r6.stdout)
  println(run-output("printf", ["%s-%s", "a", "b"]))
  println(catch(fn(e) "failed as expected", { run-output("sh", ["-c", "exit 2"]) }))
  println(catch(fn(e) "missing program", { run("koka-no-such-program-xyz").stdout }))
  // environment
  set-env("KOKA_SET_TEST", "42")
  println(get-env-value("KOKA_SET_TEST"))
  println(run("sh", ["-c", "echo $KOKA_SET_TEST"]).stdout)
  unset-env("KOKA_SET_TEST")
  println(get-env-value("KOKA_SET_TEST"))
  // stderr and tty
  eprintln("to stderr")
  println(stdin-is-tty() || True)
  flush()
