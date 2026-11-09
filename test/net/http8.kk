// Streaming HTTP bodies: downloads and uploads on the client, streamed
// responses on the server
import std/async
import std/async/os/net
import std/async/os/http
import std/time/duration

fun route( req : http-request ) : <async,exn,ndet> http-response
  match req.path
    "/numbers" -> stream-response(200, "text/plain") fn(write)
      for(1, 5) fn(i)
        write((i.show ++ "\n").bytes)
        wait(20.milli-seconds)
    "/big" -> stream-response(200, "text/plain") fn(write)
      for(1, 2000) fn(i) write(("line " ++ i.show ++ "\n").bytes)
    "/fixed" -> text-response(200, "a fixed body\n".repeat(1000), [("Content-Type", "text/plain")])
    "/echo" -> text-response(200, "got " ++ req.body.length.show ++ " bytes, " ++ req.body-text.lines.length.show ++ " lines")
    "/moved" -> Http-response(302, "Found", [("Location", "/numbers")])
    _ -> text-response(404, "no route")

fun main()
  val server = tcp-listen("127.0.0.1", 0)
  val base = "http://127.0.0.1:" ++ server.local-port.show
  val results = firstof({ http-serve(server, route, compress = True); [] }, {
    // a streamed (chunked) response, read part by part
    val parts = http-stream("GET", base ++ "/numbers") fn(res, body)
      (res.status, res.header("Transfer-Encoding"), body.map(fn(b) b.string).list)
    // a large streamed response, processed line by line
    val nlines = http-stream("GET", base ++ "/big") fn(_, body)
      body.lines.foldl(0, fn(n, l) n + (if l.starts-with("line").is-just then 1 else 0))
    // a fixed-length response, compressed by the server and decoded while reading
    val fixed = http-stream("GET", base ++ "/fixed") fn(res, body)
      (res.header("Content-Encoding"), body.read-text.count)
    // the same, without decoding
    val undecoded = http-stream("GET", base ++ "/fixed", headers = [("Accept-Encoding", "gzip")]) fn(res, body)
      (res.header("Content-Encoding"), body.byte-count < 12000)
    // an upload from a stream
    val up = http-stream("POST", base ++ "/echo", upload = Just(range(1, 3000).map(fn(i) (i.show ++ "\n").bytes))) fn(_, body)
      body.read-text
    // redirects are followed
    val moved = http-stream("GET", base ++ "/moved") fn(res, body)
      (res.status, body.read-text.lines.length)
    // the whole-body API sees the streamed response too
    val whole = http-get(base ++ "/numbers").body-text.lines
    [parts.show, nlines.show, fixed.show, undecoded.show, up, moved.show, whole.show]
  })
  results.foreach(println)
  // over HTTP/2 a streamed response is collected
  val h2 = firstof({ http-serve(server, route); "" }, {
    with client = http-client(h2c = True)
    val r = client.http-get(base ++ "/numbers")
    r.version ++ " " ++ r.body-text.lines.show
  })
  println(h2)
  server.close
