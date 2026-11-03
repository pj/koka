// HTTP idle and request timeouts (server and client)
import std/async
import std/async/os/net
import std/async/os/http
import std/time/duration

fun route( req : http-request ) : <async,exn,ndet> http-response
  match req.path
    "/hint" -> text-response(200, req.peer, [("Keep-Alive", "timeout=1")])   // the client must not reuse this
    _       -> text-response(200, req.peer)

fun get-text( port : int, path : string ) : string
  "GET " ++ path ++ " HTTP/1.1\r\nHost: x\r\n\r\n"

fun status-lines( text : string ) : list<string>
  text.split("\r\n").filter(fn(l) l.starts-with("HTTP/").is-just)

fun main()
  // --- server ---
  val server = tcp-listen("127.0.0.1", 0)
  val port = server.local-port
  val res = firstof({ http-serve(server, route, idle-timeout = 300.milli-seconds, request-timeout = 300.milli-seconds); [] }) {
    // a second request within the idle timeout uses the same connection; after
    // the idle timeout the server closes it
    val kept = tcp-connect("127.0.0.1", port) fn(c)
      c.write-text(get-text(port, "/a"))
      val r1 = c.read.string
      wait(100.milli-seconds)
      c.write-text(get-text(port, "/b"))
      val r2 = c.read.string
      val closed = timeout(2.seconds) { c.read-all-text }
      (r1.status-lines ++ r2.status-lines).join(", ") ++ "; closed after idle: " ++ (closed == Just("")).show
    // a request that arrives too slowly gets a 408
    val slow = tcp-connect("127.0.0.1", port) fn(c)
      c.write-text("GET /slow HTTP/1.1\r\nHost: x\r\n")
      timeout(2.seconds) { c.read-all-text }.map(status-lines).default(["no response"]).join(", ")
    [kept, "slow request: " ++ slow]
  }
  res.foreach(println)
  server.close
  // the default timeout is announced to clients
  val server2 = tcp-listen("127.0.0.1", 0)
  val announced = firstof({ http-serve(server2, route); "" }) {
    with client = http-client()
    client.http-get("http://127.0.0.1:" ++ server2.local-port.show ++ "/").header("Keep-Alive").default("none")
  }
  println("announced: " ++ announced)
  // --- client ---
  val base = "http://127.0.0.1:" ++ server2.local-port.show
  val client-res = firstof({ http-serve(server2, route); [] }) {
    fun same-conn( client : http-client, path : string, pause : duration ) : <async,exn,net,ndet> bool
      val a = client.http-get(base ++ path).body-text
      wait(pause)
      a == client.http-get(base ++ path).body-text
    val short = http-client(idle-timeout = 100.milli-seconds)
    val long = http-client(idle-timeout = 10.seconds)
    val r = [ "reused within the client timeout: " ++ same-conn(long, "/", 300.milli-seconds).show,
              "reused after the client timeout: " ++ same-conn(short, "/", 300.milli-seconds).show,
              "reused when the server announces timeout=1: " ++ same-conn(long, "/hint", 0.milli-seconds).show ]
    short.close
    long.close
    r
  }
  client-res.foreach(println)
  server2.close
