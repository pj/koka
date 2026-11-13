// http-stream over HTTP/2 (h2c): streamed responses with flow control, a
// full-duplex echo of an upload, stopping early, and redirects
import std/async
import std/async/os/net
import std/async/os/http
import std/time/duration

val part = "0123456789abcdef".repeat(4096).bytes   // 64 KiB

fun route( req : http-request, body : byte-stream<<async,exn,ndet>> ) : <async,exn,ndet,div> http-response
  match req.path
    "/numbers" -> stream-response(200, "text/plain") fn(write)
      for(1, 5) fn(i)
        write((i.show ++ "\n").bytes)
        wait(10.milli-seconds)
    // 4 MiB: more than the flow control windows, so the client must give them back as it reads
    "/big" -> stream-response(200, "application/octet-stream") fn(write)
      for(1, 64) fn(_) write(part)
    // echo the body while it is read
    "/echo" -> stream-response(200, "application/octet-stream") fn(write) body.foreach(fn(p) write(p))
    "/count" -> text-response(200, body.byte-count.show ++ " bytes")
    "/moved" -> Http-response(302, "Found", [("Location", "/numbers")])
    _ -> text-response(404, "no route")

fun serve( server : tcp-server ) : <async,exn,ndet> ()
  http-serve-stream(server, route)

fun main()
  val server = tcp-listen("127.0.0.1", 0)
  val base = "http://127.0.0.1:" ++ server.local-port.show
  val results = firstof({ serve(server); [] }, {
    val numbers = http-stream("GET", base ++ "/numbers", h2c = True) fn(res, body)
      (res.version, res.status, body.map(fn(b) b.string).list.join.lines)
    val big = http-stream("GET", base ++ "/big", h2c = True) fn(_, body)
      body.byte-count
    // 8 MiB echoed while it is uploaded: the server writes the echo before it
    // reads more, so the client must read the response while it sends
    val echoed = timeout(30.seconds) {
      http-stream("POST", base ++ "/echo", h2c = True, upload = Just(range(1, 128).map(fn(_) part))) fn(_, body)
        body.byte-count
    }
    // stop after the first part: the stream is reset, and the server stops
    val first = http-stream("GET", base ++ "/big", h2c = True) fn(_, body)
      body.read-bytes(10).fst.string
    val counted = http-stream("POST", base ++ "/count", h2c = True, upload = Just(range(1, 3).map(fn(_) part))) fn(_, body)
      body.read-text
    val moved = http-stream("GET", base ++ "/moved", h2c = True) fn(res, body)
      (res.status, body.read-text.lines.length)
    // with h2c off, the same server answers over HTTP/1.1
    val h1 = http-stream("GET", base ++ "/numbers") fn(res, body)
      (res.version, body.read-text.lines.length)
    [numbers.show, big.show, echoed.show, first, counted, moved.show, h1.show]
  })
  results.foreach(println)
  server.close
