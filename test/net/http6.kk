// HTTP/2 interoperability with Node.js (its http2 module): our client against
// Node's server, and Node's client against our server, over h2c and TLS.
// Needs `node` on the PATH; the scripts are in h2-interop/. The certificates
// are the ones of tls2.kk.
import std/async
import std/async/os/net
import std/async/os/tls
import std/async/os/http
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

val env = [("KK_CERT", server-cert), ("KK_KEY", server-key), ("KK_CA", ca-cert)]

fun show-res( r : http-response ) : string
  r.version ++ " " ++ r.status.show ++ " " ++ (if r.body.length > 100 then r.body.length.show ++ " bytes" else r.body-text)

fun route( req : http-request ) : <async,exn,ndet> http-response
  match req.path
    "/big"  -> text-response(200, "y".repeat(200000))
    "/echo" -> bytes-response(200, req.body, "application/octet-stream")
    _       -> text-response(200, req.version ++ " " ++ req.method ++ " " ++ req.path)

// read the first line of the output of a process
fun first-line( p : process, acc : string ) : <async,exn,div> string
  match acc.find("\n")
    Just(sl) -> sl.before.string
    Nothing ->
      val more = p.read-stdout
      if more.is-empty then acc else p.first-line(acc ++ more.string)

// the scripts, relative to the test directory or to the repository root
fun script( name : string ) : io string
  val local = "h2-interop/" ++ name
  if path-exists(local.path) then local else "test/net/h2-interop/" ++ name

fun main()
  // our client, Node's server
  with node = spawn("node", [script("server.mjs")], env = env, stderr = Inherit)
  val ports = node.first-line("").split(" ")
  val (plain, secure) = match ports
    ["ports", p1, p2] -> ("http://127.0.0.1:" ++ p1, "https://localhost:" ++ p2)
    _ -> throw("unexpected output from the node server: " ++ ports.join(" "))
  with client = http-client(h2c = True, tls-ca = ca-cert)
  println("h2c: " ++ client.http-get(plain ++ "/hello").show-res)
  println("tls: " ++ client.http-get(secure ++ "/hello").show-res)
  println("download: " ++ client.http-get(secure ++ "/big").show-res)
  val up = client.http-post(secure ++ "/echo", "q".repeat(300000).bytes)   // more than Node's 64 KB window
  println("upload: " ++ up.show-res ++ ", received " ++ up.header("x-received").default("-"))
  val many = interleaved(list(1, 10).map(fn(i) fn() client.http-get(plain ++ "/n" ++ i.show).status))
  println("concurrent: " ++ many.show)
  val ups = interleaved(list(1, 3).map(fn(i) fn() client.http-post(secure ++ "/echo", "w".repeat(100000 * i).bytes).header("x-received").default("-")))
  println("concurrent uploads: " ++ ups.join(","))
  node.close-stdin
  println("node server exit: " ++ node.wait.show)
  // Node's client, our server
  val config = tls-server-config(server-cert, server-key, alpn = ["h2", "http/1.1"])
  val ps = tcp-listen("127.0.0.1", 0)
  val ts = tcp-listen("127.0.0.1", 0)
  fun node-client() : <async,io> string
    run-process("node", [script("client.mjs"), ps.local-port.show, ts.local-port.show], env = env).stdout
  val out = firstof({ http-serve(ps, route); "" }) {
    firstof({ http-serve(ts, route, tls = Just(config)); "" }, node-client)
  }
  out.split("\n").filter(fn(l) !l.is-empty).foreach(println)
  ps.close
  ts.close
