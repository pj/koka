import std/async
import std/time
import std/async/os/net
import std/async/os/http
import std/async/os/websocket

fun route( req : http-request ) : <async,exn,ndet> http-response
  match req.path
    "/echo" -> websocket-response(req, fn(ws) {
        ws.foreach fn(msg)
          match msg
            Text("bye") -> ws.close(4000, "asked to")
            _ -> ws.send(msg)
      }, protocols = ["chat", "superchat"])
    "/count" -> websocket-response(req) fn(ws)
      ws.send-text("protocol=" ++ ws.protocol.show)
      var n := 0
      ws.foreach fn(msg)
        if msg == Text("done") then ws.send-text("received " ++ n.show) else n := n + 1
    "/fail" -> websocket-response(req) fn(_)
      throw("handler failed")
    _ -> text-response(404, "no route")

// A raw client: do the handshake by hand, send `frames`, and return what the server sends back.
fun raw-client( port : int, frames : bytes ) : <async,exn,net> bytes
  with c = tcp-connect("127.0.0.1", port)
  c.write-text("GET /echo HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
               "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
  c.write-all(frames)
  c.read-all

// A masked client frame (with a zero mask, so the payload is unchanged).
fun frame( b0 : int, payload : list<int> ) : bytes
  ([b0, 128 + payload.length, 0, 0, 0, 0] ++ payload).vector.bytes

fun after-head( b : bytes ) : list<int>
  val s = b.list
  fun go( xs : list<int> ) : list<int>
    match xs
      Cons(13, Cons(10, Cons(13, Cons(10, rest)))) -> rest
      Cons(_, rest) -> go(rest)
      Nil -> []
  go(s)

fun main()
  val server = tcp-listen("127.0.0.1", 0)
  val port = server.local-port
  val base = "ws://127.0.0.1:" ++ port.show
  firstof({ http-serve(server, route) }, {
    // echo, with a subprotocol
    with ws = websocket-connect(base ++ "/echo", protocols = ["superchat", "chat"])
    println("protocol: " ++ ws.protocol)
    ws.send-text("hello")
    println(ws.receive)
    ws.send-binary([0, 1, 2, 255].vector.bytes)
    println(ws.receive.map(fn(m) match m { Binary(b) -> b.list.show; Text(t) -> t }))
    val big = "x".repeat(200000)
    ws.send-text(big)
    println(ws.receive == Just(Text(big)))
    val mid = "é".repeat(40000)
    ws.send-text(mid)
    println(ws.receive == Just(Text(mid)))
    ws.ping("p".bytes)
    ws.send-text("after ping")
    println(ws.receive)
    ws.send-text("bye")
    println(ws.receive)
    println((ws.close-code, ws.close-reason))
    println(catch(fn(e) e.message, { ws.send-text("too late"); "sent" }))
  })
  firstof({ http-serve(server, route) }, {
    with ws = websocket-connect(base ++ "/count")
    println(ws.receive)
    for(1, 3) fn(i) ws.send-text(i.show)
    ws.send-text("done")
    println(ws.receive)
    ws.close(1001, "going away")
    println("client: closed, server answered " ++ ws.close-code.show)
    wait(100.milli-seconds)
  })
  firstof({ http-serve(server, route) }, {
    // one strand receives while another sends and closes
    with ws = websocket-connect(base ++ "/echo")
    val (got, _) = interleaved({
      var n := 0
      ws.foreach fn(_) n := n + 1
      n
    }, {
      ws.send-text("a")
      ws.send-text("b")
      wait(100.milli-seconds)
      ws.close(1000, "both")
    })
    println(("received while closing", got, ws.close-code))
  })
  firstof({ http-serve(server, route) }, {
    // a handler exception closes with 1011
    with ws = websocket-connect(base ++ "/fail")
    println((ws.receive, ws.close-code))
    // refused handshakes
    println(catch(fn(e) e.message, { val _ = websocket-connect(base ++ "/nothing"); "connected" }))
    // no common subprotocol: the server chooses none
    with other = websocket-connect(base ++ "/echo", protocols = ["other"])
    println("chosen: " ++ other.protocol.show)
    other.close
    val plain = http-get("http://127.0.0.1:" ++ port.show ++ "/echo")
    println((plain.status, plain.body-text))
    // raw frames: a fragmented text message, a ping in between, then a close
    val r1 = raw-client(port, frame(0x01, [104, 101]) ++ frame(0x89, [7]) ++ frame(0x80, [121]) ++ frame(0x88, [3, 232]))
    println(r1.after-head)
    // invalid UTF-8 closes with 1007; an unmasked frame with 1002
    println(raw-client(port, frame(0x81, [0xC0, 0x80])).after-head)
    println(raw-client(port, [0x81, 1, 65].vector.bytes).after-head)
    // a continuation frame without a message
    println(raw-client(port, frame(0x80, [65])).after-head)
  })
  server.close
  println((is-valid-utf8("héllo €𝄞".bytes), is-valid-utf8([0xED, 0xA0, 0x80].vector.bytes), is-valid-utf8([0xF4, 0x90, 0x80, 0x80].vector.bytes)))
