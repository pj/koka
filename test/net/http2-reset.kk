// HTTP/2 client: a server that closes a connection (without a GOAWAY, as when
// the reset discards it on Windows) while a request is being sent on it, which
// it has not processed: the request is retried on a new connection.
// The server here is a minimal HTTP/2 server on plain TCP.
import std/async
import std/async/os/net
import std/async/os/http
import std/time/duration

// The frames in `buf` after the connection preface: (type, stream id).
fun frames( buf : bytes, pos : int ) : div list<(int, int)>
  if pos + 9 > buf.length then [] else
    val len = buf.at(pos) * 65536 + buf.at(pos + 1) * 256 + buf.at(pos + 2)
    if pos + 9 + len > buf.length then []
    else Cons((buf.at(pos + 3), buf.at(pos + 8)), frames(buf, pos + 9 + len))

fun at( b : bytes, i : int ) : int
  b.subbytes(i, 1).list.head(0)

// Read until a HEADERS frame (type 1) for stream `sid` has arrived.
fun read-headers( s : tcp-socket, acc : bytes, sid : int ) : <async,exn,div> bytes
  if acc.length >= 24 && frames(acc, 24).any(fn((t, i)) t == 1 && i == sid) then acc
  else
    val more = s.read
    if more.is-empty then throw("closed") else read-headers(s, acc ++ more, sid)

val settings = [0, 0, 0, 4, 0, 0, 0, 0, 0].vector.bytes
// HEADERS on stream `sid` with `:status: 200` (static table index 8) and
// END_STREAM, and RST_STREAM with NO_ERROR: the rest of the body is not needed
fun ok( sid : int ) : bytes
  [0, 0, 1, 1, 5, 0, 0, 0, sid, 0x88, 0, 0, 4, 3, 0, 0, 0, 0, sid, 0, 0, 0, 0].vector.bytes

// The first connection answers one request and is closed when the second
// request arrives; later connections answer one request.
fun conn( s : tcp-socket, first : bool ) : <async,exn,div> ()
  val buf = read-headers(s, bytes/empty, 1)
  s.write-all(settings ++ ok(1))
  if first then
    val _ = read-headers(s, buf, 3)
    s.close
  else
    wait(500.milli-seconds)
    s.close

fun main()
  val server = tcp-listen("127.0.0.1", 0)
  val base = "http://127.0.0.1:" ++ server.local-port.show
  val big = "0123456789".repeat(400000).bytes   // more than the initial window
  val n = ref(0)
  firstof({
    serve(server, fn(s) {
      n := !n + 1
      val first = (!n == 1)
      conn(s, first)
    })
  }, {
    with client = http-client(h2c = True)
    println(("first", client.http-get(base ++ "/").status))
    println(("retried", client.http-post(base ++ "/", big).status, !n))
  })
  server.close
