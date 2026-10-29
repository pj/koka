import std/async
import std/async/os/net
import std/async/os/http

fun route( req : http-request ) : <async,exn,ndet> http-response
  match req.path
    "/hello" -> text-response(200, "hello " ++ req.query-param("name").default("world"))
    "/echo"  -> bytes-response(200, req.body, req.header("Content-Type").default("application/octet-stream"))
    "/fail"  -> throw("route failed")
    _ -> text-response(404, "no route for " ++ req.path)

fun main()
  val server = tcp-listen("127.0.0.1", 0)
  val port = server.local-port
  val base = "http://127.0.0.1:" ++ port.show
  val results = firstof({ http-serve(server, route); [] }, {
    val r1 = http-get(base ++ "/hello?name=koka%20lang")
    val r2 = http-post(base ++ "/echo", "some data".bytes, "text/plain")
    val r3 = http-get(base ++ "/missing")
    val r4 = http-get(base ++ "/fail")
    val big = "x".repeat(200000)
    val r5 = http-post(base ++ "/echo", big.bytes)
    [ (r1.status, r1.body-text, r1.header("content-type").default("")),
      (r2.status, r2.body-text, r2.header("Content-Type").default("")),
      (r3.status, r3.body-text, r3.reason),
      (r4.status, r4.body-text, ""),
      (r5.status, (r5.body-text == big).show, r5.header("content-length").default("")) ]
  })
  results.foreach(fn(r) println(r))
  // keep-alive: two pipelined requests on one connection
  val pipelined = firstof({ http-serve(server, route); "" }, {
    with c = tcp-connect("127.0.0.1", port)
    c.write-text("GET /hello?name=one HTTP/1.1\r\nHost: x\r\n\r\nGET /hello?name=two HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    c.read-all-text
  })
  println(pipelined.split("\r\n").filter(fn(l) l.starts-with("hello").is-just || l.starts-with("HTTP").is-just))
  server.close
  // a hand-written server that answers with a chunked response
  val rawsrv = tcp-listen("127.0.0.1", 0)
  val rport = rawsrv.local-port
  val (_, chunked) = interleaved({
    rawsrv.accept fn(c)
      val _ = c.read
      c.write-text("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n7;ext=1\r\n, world\r\n0\r\nX-Trailer: t\r\n\r\n")
  }, {
    http-get("http://127.0.0.1:" ++ rport.show ++ "/").body-text
  })
  println(chunked)
  rawsrv.close
  println(catch(fn(e) e.message, { http-get("https://example.com/").body-text }))
