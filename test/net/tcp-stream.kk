// Byte streams from sockets, child processes and asynchronous files
import std/async
import std/async/os/net
import std/async/os/process
import std/async/os/file
import std/os/fs

// A tiny line protocol: a header line `LEN <n>`, then `n` bytes, then more lines.
fun serve-one( conn : tcp-socket ) : <async,exn,div> ()
  val s = conn.stream
  match s.read-line
    Nothing -> conn.write-text("no header\n")
    Just((header, rest)) ->
      val n = header.slice.drop(4).string.parse-int.default(0)
      val (body, rest2) = rest.read-bytes(n)
      conn.write-text("body: " ++ body.string ++ "\n")
      rest2.lines.foreach-indexed fn(i, l)
        conn.write-text(i.show ++ ": " ++ l.to-upper ++ "\n")
      conn.write-text("bye\n")

fun main()
  val server = tcp-listen("127.0.0.1", 0)
  val port = server.local-port
  val (_, reply) = interleaved({
    server.accept(serve-one)
  }, {
    with c = tcp-connect("127.0.0.1", port)
    c.write-text("LEN 11\nhello")
    c.write-text(" world")       // the body arrives in two parts
    c.write-text("first\nsecond line\nlast")
    c.shutdown-write
    c.stream.lines.list
  })
  println(reply)

  // a large transfer, counted as it arrives
  val (_, counted) = interleaved({
    with c = server.accept
    for(1, 20000) fn(i) c.write-text(i.show ++ "\n")
  }, {
    with c = tcp-connect("127.0.0.1", port)
    c.stream.lines.foldl((0, 0), fn((n, total), l) (n + 1, total + l.parse-int.default(0)))
  })
  println(counted)
  server.close

  // the output of a child process, line by line as it is produced
  val (output, code) = spawn("sh", ["-c", "for i in 1 2 3; do echo line $i; done; echo oops >&2; exit 2"]) fn(p)
    val ls = p.stdout-stream.lines.map(fn(l) l.to-upper).list
    val err = p.stderr-stream.read-text
    ((ls, err), p.wait)
  println((output, code))
  val first = spawn("sh", ["-c", "echo ready; sleep 10"]) fn(p)
    val l = p.stdout-stream.lines.head   // does not wait for the process to finish
    p.kill
    l
  println(first)

  // an asynchronous file, and the same file through std/os/fs
  with-temp-dir fn(dir)
    val f = dir / "lines.txt"
    write-stream(f, range(1, 1000).map(show).unlines)
    with fd = fd-open(f, Read)
    println(fd.stream(100).lines.drop(997).list)
    with-file(f, Read) fn(h)
      println(h.stream.lines.length)
