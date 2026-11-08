// HTTP compression: gzip responses from the server, decoded by the client
import std/async
import std/async/os/net
import std/async/os/http
import std/compress

val page = "<p>hello compressed world</p>\n".repeat(200)

fun route( req : http-request ) : <async,exn,ndet> http-response
  match req.path
    "/page"  -> text-response(200, page, [("Content-Type", "text/html")])
    "/small" -> text-response(200, "tiny")
    "/png"   -> bytes-response(200, page.bytes, "image/png")
    "/seen"  -> text-response(200, req.header("Accept-Encoding").default("(none)"))
    _ -> text-response(404, "no route")

fun show-res( r : http-response ) : string
  [r.status.show, r.header("Content-Encoding").default("-"), r.header("Vary").default("-"),
   r.body.length.show, (r.body-text == page).show].join(" ")

fun main()
  val server = tcp-listen("127.0.0.1", 0)
  val port = server.local-port
  val base = "http://127.0.0.1:" ++ port.show
  val lines = firstof({ http-serve(server, route, compress = True); [] }, {
    val packed = http-get(base ++ "/page", [("Accept-Encoding", "gzip")])
    [ "decoded: " ++ http-get(base ++ "/page").show-res,
      "sent: " ++ http-get(base ++ "/seen").body-text,
      "raw: " ++ packed.show-res ++ " " ++ (packed.body.gunzip.string == page).show,
      "identity: " ++ http-get(base ++ "/page", [("Accept-Encoding", "identity")]).show-res,
      "refused: " ++ http-get(base ++ "/page", [("Accept-Encoding", "gzip;q=0, deflate")]).show-res,
      "small: " ++ http-get(base ++ "/small", [("Accept-Encoding", "gzip")]).show-res,
      "binary: " ++ http-get(base ++ "/png", [("Accept-Encoding", "gzip")]).show-res,
      "head: " ++ http-request("HEAD", base ++ "/page").show-res ]
  })
  lines.foreach(println)

  // over HTTP/2 (prior knowledge) too
  val h2 = firstof({ http-serve(server, route, compress = True); "" }, {
    with client = http-client(h2c = True)
    val r = client.http-get(base ++ "/page")
    r.version ++ " " ++ r.show-res
  })
  println("h2: " ++ h2)
  server.close

  // the client decodes deflate (zlib and raw) and gzip from any server
  val raw-server = tcp-listen("127.0.0.1", 0)
  val raw-port = raw-server.local-port
  val bodies = [("deflate", page.bytes.compress(Zlib)), ("deflate", page.bytes.deflate), ("gzip", page.bytes.gzip),
                ("gzip, gzip", page.bytes.gzip.gzip), ("br", "unknown".bytes)]
  bodies.foreach fn((enc, payload))
    val (_, res) = interleaved({
      with c = raw-server.accept
      val _ = c.stream.read-until(10)
      c.write-all(("HTTP/1.1 200 OK\r\nContent-Encoding: " ++ enc ++ "\r\nContent-Length: " ++ payload.length.show ++ "\r\nConnection: close\r\n\r\n").bytes ++ payload)
    }, {
      val r = http-get("http://127.0.0.1:" ++ raw-port.show ++ "/")
      enc ++ ": " ++ r.header("Content-Encoding").default("-") ++ " " ++ (r.body-text == page).show ++ " " ++ r.body.length.show
    })
    println(res)
  raw-server.close
