// Asynchronous child processes
import std/async
import std/async/os/process
import std/time/duration
import std/time/timer
import std/os/path

fun main()
  // run to completion
  val r1 = run-process("sh", ["-c", "echo out; echo err >&2; exit 3"])
  println((r1.exit-code, r1.stdout, r1.stderr))
  println(run-process("cat", input = "fed through stdin").stdout)
  println(run-process("sh", ["-c", "echo $KK_TEST_VAR; pwd"], env = [("KK_TEST_VAR", "from env")], cwd = "/usr/bin".path).stdout)
  println(run-process-output("tr", ["a-z", "A-Z"], input = "upper"))
  // large output and input (more than a pipe buffer)
  val big = "0123456789".repeat(50000)
  val r2 = run-process("cat", input = big)
  println((r2.exit-code, r2.stdout.count, r2.stdout == big))
  // a program that exits without reading its input
  println(run-process("true", input = big).exit-code)
  // unknown program
  println(catch(fn(e) "error: " ++ (if e.message.contains("unable to run") then "unable to run" else e.message), { run-process("no-such-program-kk").stdout }))
  // interactive use
  val sorted = spawn("sort", []) fn(p)
    p.write-stdin("banana\ncherry\napple\n")
    p.close-stdin
    val out = p.read-all-stdout.string
    (out, p.wait)
  println(sorted)
  // concurrent processes run in parallel: three 0.5s sleeps finish in well under 1.5s
  val t0 = ticks()
  val codes = interleaved([{ run-process("sleep", ["0.5"]).exit-code }, { run-process("sleep", ["0.5"]).exit-code }, { run-process("sleep", ["0.5"]).exit-code }])
  println((codes, (ticks() - t0) < 1.2.duration))
  // killing
  val killed = spawn("sleep", ["10"]) fn(p)
    p.kill
    p.wait
  println(killed)
  // a timeout cancels (and kills) the process
  val t1 = ticks()
  println(timeout(0.2.duration) { run-process("sleep", ["10"]).exit-code })
  println((ticks() - t1) < 5.duration)
  // output sent to the null device
  val ignored = spawn("sh", ["-c", "echo ignored"], stdin = Ignore, stdout = Ignore) fn(p : process)
    (p.wait, catch(fn(e) e.message, { p.read-stdout.string }))
  println(ignored)
