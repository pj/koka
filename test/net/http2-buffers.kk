// HTTP/2 with small socket buffers (as on Windows loopback): a server that
// echoes a large body while it reads it, and a client that sends it, must keep
// reading while they write (they used to deadlock with each waiting to write)
import std/async
import std/async/os/net
import std/async/os/http
import std/os/env
import std/time/duration

fun route( req : http-request, body : byte-stream<<async,exn,ndet>> ) : <async,exn,ndet,div> http-response
  stream-response(200, "text/plain") fn(write) body.foreach(fn(part) write(part))

fun serve( server : tcp-server ) : <async,exn,ndet> ()
  http-serve-stream(server, route)

fun main()
  set-env("KK_NET_SMALL_BUFFERS", "1")   // read by the C backend when a socket starts reading
  val server = tcp-listen("127.0.0.1", 0)
  val base = "http://127.0.0.1:" ++ server.local-port.show
  val huge = "0123456789abcdef".repeat(250000).bytes   // 4 MB, beyond the 1 MiB windows
  firstof({ serve(server) }, {
    with client = http-client(h2c = True)
    match timeout(60.seconds, { client.http-post(base ++ "/echo", huge) })
      Just(e) -> println(("echo", e.version, e.body.length == huge.length, e.body-text == huge.string))
      Nothing -> println("echo: timed out")
    val two = interleaved(list(1, 2).map(fn(_) fn() client.http-post(base ++ "/echo", huge).body.length))
    println(("concurrent", two))
  })
  server.close
