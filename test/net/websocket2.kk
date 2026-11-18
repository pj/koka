// WebSocket interoperability with Node.js (its built-in WebSocket client)
// against our server over ws and wss, and our client over wss. Needs `node`
// on the PATH; the script is in ws-interop/. The certificates are the ones of
// tls2.kk.
import std/async
import std/async/os/net
import std/async/os/tls
import std/async/os/http
import std/async/os/websocket
import std/async/os/process
import std/os/path
import std/os/fs

val ca-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBlTCCATugAwIBAgIUashCYhy/dqFQFg7usCgT500dw1EwCgYIKoZIzj0EAwIw\n"
  ++ "FzEVMBMGA1UEAwwMS29rYSBUZXN0IENBMCAXDTI2MTAyOTIyMjcyOFoYDzIxMjYx\n"
  ++ "MDA1MjIyNzI4WjAXMRUwEwYDVQQDDAxLb2thIFRlc3QgQ0EwWTATBgcqhkjOPQIB\n"
  ++ "BggqhkjOPQMBBwNCAASrkBUeC966brM3242HKoyFiwNyzo+SZyqD6Idexr0Dn7Ch\n"
  ++ "GDumkVG3aOTyXfRBrguoXZpmJqCzOG+fSs7jJUlQo2MwYTAdBgNVHQ4EFgQUe8lB\n"
  ++ "X5XhyxNLexKKEjKJalcs2TYwHwYDVR0jBBgwFoAUe8lBX5XhyxNLexKKEjKJalcs\n"
  ++ "2TYwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAgQwCgYIKoZIzj0EAwID\n"
  ++ "SAAwRQIgLDPhs24PnCj4I6jFRUzW2vrVU2gFr2r9hlA43Fr1fuoCIQDiD1yYl4M+\n"
  ++ "dXxODGQ3V/xs0Hgny3tMF4aQQ5C3+2orbg==\n"
  ++ "-----END CERTIFICATE-----\n"

val server-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBvDCCAWKgAwIBAgIUWlEgKgLhjVrKa2lI7aVJd4RaSGAwCgYIKoZIzj0EAwIw\n"
  ++ "FzEVMBMGA1UEAwwMS29rYSBUZXN0IENBMCAXDTI2MTAyOTIyMjcyOFoYDzIxMjYx\n"
  ++ "MDA1MjIyNzI4WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggq\n"
  ++ "hkjOPQMBBwNCAATLb0puFqNJNpx5Kry5Y7wMgpCvK1qbVKSvlmk6fSZQt89Dcocf\n"
  ++ "lpmYlN+ujk0BFOKFvMTDynBoTe8qDO0++Xwmo4GMMIGJMBoGA1UdEQQTMBGCCWxv\n"
  ++ "Y2FsaG9zdIcEfwAAATAJBgNVHRMEAjAAMAsGA1UdDwQEAwIHgDATBgNVHSUEDDAK\n"
  ++ "BggrBgEFBQcDATAdBgNVHQ4EFgQU/ke/pJ6Y5VQFAgNo3Ldi+NSPLQQwHwYDVR0j\n"
  ++ "BBgwFoAUe8lBX5XhyxNLexKKEjKJalcs2TYwCgYIKoZIzj0EAwIDSAAwRQIhAJCg\n"
  ++ "KmQkaK9LyoqfHXz3VDFtoqhg2pRXf7j/OpQLu7dQAiAyZcQZ4c7MwxUwR6sQDbmi\n"
  ++ "ILxifzYLmWnuH7X4vaN+yQ==\n"
  ++ "-----END CERTIFICATE-----\n"

val server-key = "-----BEGIN PRIVATE KEY-----\n"
  ++ "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgThUhhZJJgYY9zUOY\n"
  ++ "EeP6tiiXznPhgIN4M/vanWLFy4qhRANCAATLb0puFqNJNpx5Kry5Y7wMgpCvK1qb\n"
  ++ "VKSvlmk6fSZQt89DcocflpmYlN+ujk0BFOKFvMTDynBoTe8qDO0++Xwm\n"
  ++ "-----END PRIVATE KEY-----\n"

fun route( req : http-request ) : <async,exn,ndet> http-response
  match req.path
    "/echo" -> websocket-response(req, fn(ws) { ws.foreach(fn(msg) ws.send(msg)) }, protocols = ["chat"])
    "/bye" -> websocket-response(req) fn(ws)
      ws.send-text("bye")
      ws.close(1000, "server done")
    _ -> text-response(404, "no route")

// the script, relative to the test directory or to the repository root
fun script( name : string ) : io string
  val local = "ws-interop/" ++ name
  if path-exists(local.path) then local else "test/net/ws-interop/" ++ name

fun main()
  val config = tls-server-config(server-cert, server-key)
  val ps = tcp-listen("127.0.0.1", 0)
  val ts = tcp-listen("127.0.0.1", 0)
  // our client over wss
  val ours = firstof({ http-serve(ts, route, tls = Just(config)); "" }) {
    with ws = websocket-connect("wss://localhost:" ++ ts.local-port.show ++ "/echo", tls-ca = ca-cert)
    ws.send-text("over tls")
    ws.receive.show
  }
  println("koka wss: " ++ ours)
  // Node's client
  with-temp-dir fn(dir)
    val ca-file = dir / "ca.pem"
    write-text-file(ca-file, ca-cert)
    val env = [("NODE_EXTRA_CA_CERTS", ca-file.string)]
    fun node-client() : <async,io> string
      val r = run-process("node", [script("client.mjs"), ps.local-port.show, ts.local-port.show], env = env)
      r.stdout ++ r.stderr
    val out = firstof({ http-serve(ps, route); "" }) {
      firstof({ http-serve(ts, route, tls = Just(config)); "" }, node-client)
    }
    out.split("\n").filter(fn(l) !l.is-empty).foreach(println)
  ps.close
  ts.close
