// HTTP client connection reuse (http-client)
import std/async
import std/async/os/net
import std/async/os/http

fun route( req : http-request ) : <async,exn,ndet> http-response
  match req.path
    "/close" -> text-response(200, req.peer, [("Connection", "close")])
    "/found" -> text-response(302, "", [("Location", "/peer")])
    _        -> text-response(200, req.peer)

// the number of distinct connections that served the responses
fun connections( rs : list<http-response> ) : int
  rs.map(fn(r) r.body-text).foldl([], fn(seen, p) if seen.any(fn(q) q == p) then seen else Cons(p, seen)).length

fun main()
  val server = tcp-listen("127.0.0.1", 0)
  val base = "http://127.0.0.1:" ++ server.local-port.show
  val results = firstof({ http-serve(server, route); [] }) {
    with client = http-client()
    // sequential requests share one connection, including redirects and POSTs
    val seq = [client.http-get(base ++ "/peer"), client.http-get(base ++ "/found"),
               client.http-post(base ++ "/peer", "data".bytes), client.http-get(base ++ "/peer")]
    // a response with `Connection: close` is not reused
    val closed = [client.http-get(base ++ "/close"), client.http-get(base ++ "/peer")]
    // concurrent requests use separate connections, which are reused afterwards
    val par = interleaved([{ client.http-get(base ++ "/peer") }, { client.http-get(base ++ "/peer") }, { client.http-get(base ++ "/peer") }])
    val after = [client.http-get(base ++ "/peer"), client.http-get(base ++ "/peer")]
    // the plain functions do not reuse connections
    val plain = [http-get(base ++ "/peer"), http-get(base ++ "/peer")]
    // a closed client can still be used (with new connections)
    val before-close = client.http-get(base ++ "/peer")
    client.close
    val after-close = client.http-get(base ++ "/peer")
    [ "sequential: " ++ seq.map(fn(r) r.status.show).join(",") ++ " on " ++ seq.connections.show ++ " connection(s)",
      "close: " ++ closed.connections.show ++ " connection(s)",
      "concurrent: " ++ par.connections.show ++ ", then " ++ (par ++ after).connections.show,
      "plain: " ++ plain.connections.show,
      "after close: " ++ ([before-close, after-close].connections).show ]
  }
  results.foreach(println)
  server.close
  // a server that closes each connection after one response: the pooled
  // connection is stale, and an idempotent request is retried transparently
  val oneshot = tcp-listen("127.0.0.1", 0)
  val rbase = "http://127.0.0.1:" ++ oneshot.local-port.show
  fun respond-once( n : int ) : <async,exn> ()
    with c = oneshot.accept
    val _ = c.read
    c.write-text("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nreq-" ++ n.show)
  val stale = firstof({ respond-once(1); respond-once(2); respond-once(3); respond-once(4); [] }) {
    with client = http-client()
    val r1 = client.http-get(rbase ++ "/")
    val r2 = client.http-get(rbase ++ "/")   // the pooled connection was closed: retried
    // a POST is not retried, as the server may have processed it
    val r3 = catch(fn(_) "failed", { client.http-post(rbase ++ "/", "x".bytes).body-text })
    val r4 = client.http-get(rbase ++ "/")
    [r1.body-text, r2.body-text, "post on a stale connection: " ++ r3, r4.body-text]
  }
  stale.foreach(println)
  oneshot.close
