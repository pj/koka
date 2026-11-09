// Streaming request bodies on the server: http-serve-stream
import std/async
import std/async/os/net
import std/async/os/http

fun route( req : http-request, body : byte-stream<<async,exn,ndet>> ) : <async,exn,ndet,div> http-response
  match req.path
    // count the bytes and lines as they arrive
    "/count" ->
      val (n, parts) = body.foldl((0, 0), fn((n, k), part) (n + part.length, k + 1))
      text-response(200, n.show ++ " bytes" ++ (if parts > 1 then ", in parts" else ""))
    "/lines" -> text-response(200, body.lines.length.show ++ " lines")
    // read only the start
    "/peek" -> text-response(200, body.read-bytes(5).fst.string)
    // ignore the body
    "/ignore" -> text-response(200, "ignored")
    // echo it back while it is read, from the body writer
    "/echo" -> stream-response(200, "text/plain") fn(write) body.foreach(fn(part) write(part))
    "/peer" -> text-response(200, req.peer)
    _ -> text-response(404, "no route")

fun serve( server : tcp-server ) : <async,exn,ndet> ()
  http-serve-stream(server, route)

fun main()
  val server = tcp-listen("127.0.0.1", 0)
  val port = server.local-port
  val base = "http://127.0.0.1:" ++ port.show
  val big = list(1, 50000).map(fn(i) "line " ++ i.show ++ "\n").join
  firstof({ serve(server) }, {
    // a large body with a length, and a chunked upload
    println(http-post(base ++ "/count", big.bytes).body-text)
    println(http-post(base ++ "/lines", big.bytes).body-text)
    val up = http-stream("POST", base ++ "/count", upload = Just(range(1, 2000).map(fn(i) (i.show ++ "\n").bytes))) fn(_, b)
      b.read-all.string
    println(up)
    println(http-get(base ++ "/count").body-text)
    // the echo is streamed back
    val echo = http-stream("POST", base ++ "/echo", upload = Just(range(1, 3000).map(fn(i) (i.show ++ "\n").bytes))) fn(res, b)
      (res.header("Transfer-Encoding").default("-"), b.lines.length)
    println(echo)

    // keep-alive: the connection is kept when the body was read, closed when it was not
    with client = http-client()
    val p1 = client.http-get(base ++ "/peer").body-text
    val r1 = client.http-post(base ++ "/count", "abc".bytes)
    val p2 = client.http-get(base ++ "/peer").body-text
    println(("read body", r1.body-text, r1.header("Connection"), p1 == p2))
    val r2 = client.http-post(base ++ "/peek", big.bytes)
    val p3 = client.http-get(base ++ "/peer").body-text
    println(("partly read", r2.body-text, r2.header("Connection"), p2 == p3))
    val r3 = client.http-post(base ++ "/ignore", "abc".bytes)
    val p4 = client.http-get(base ++ "/peer").body-text
    println(("ignored", r3.body-text, r3.header("Connection"), p3 == p4))
    val r4 = client.http-post(base ++ "/echo", "echoed".bytes)
    val p5 = client.http-get(base ++ "/peer").body-text
    println(("echo", r4.body-text, r4.header("Connection"), p4 == p5))

    // Expect: 100-continue is answered when the body is read
    println(expect-continue(port, "/count"))
    println(expect-continue(port, "/ignore"))
  })

  // the buffered server answers Expect: 100-continue too
  firstof({ http-serve(server, fn(req) text-response(200, req.body.length.show ++ " bytes")) }, {
    println(expect-continue(port, "/"))
  })

  // over HTTP/2 (prior knowledge): bodies larger than the flow control window
  // (1 MiB) are read as they arrive, and streamed back
  val huge = big.repeat(6)
  firstof({ serve(server) }, {
    with client = http-client(h2c = True)
    val r = client.http-post(base ++ "/count", huge.bytes)
    println((r.version, r.body-text))
    val p1 = client.http-get(base ++ "/peer").body-text
    println(("partly read", client.http-post(base ++ "/peek", huge.bytes).body-text))
    println(("ignored", client.http-post(base ++ "/ignore", huge.bytes).body-text))
    val e = client.http-post(base ++ "/echo", huge.bytes)
    println(("echo", e.body.length == huge.bytes.length, e.body-text == huge))
    println(("lines", client.http-post(base ++ "/lines", big.bytes).body-text))
    println(("same connection", client.http-get(base ++ "/peer").body-text == p1))
  })
  // the buffered server over HTTP/2
  firstof({ http-serve(server, fn(req) text-response(200, req.body.length.show ++ " bytes")) }, {
    with client = http-client(h2c = True)
    val r = client.http-post(base ++ "/", huge.bytes)
    println((r.version, r.body-text))
  })
  server.close

// Send the head with `Expect: 100-continue`, and the body only after the `100 Continue`.
fun expect-continue( port : int, path : string ) : <async,exn,net> string
  with c = tcp-connect("127.0.0.1", port)
  c.write-all(("POST " ++ path ++ " HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n").bytes)
  val first = c.read.string
  if first.starts-with("HTTP/1.1 100").is-just then
    c.write-all("hello".bytes)
    val rest = (first ++ c.read-all.string).split("\r\n")
    "continued: " ++ rest.drop(2).head.default("") ++ " / " ++ rest.last.default("")
  else "no continue: " ++ first.split("\r\n").head.default("") ++ " / " ++ first.split("\r\n").last.default("")
