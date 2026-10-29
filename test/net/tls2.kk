// TLS server (tls-accept, http-serve with tls) against a test CA; no internet needed.
// The certificates are valid until 2126: see the end of this file for how they were made.
import std/async
import std/async/os/net
import std/async/os/tls
import std/async/os/http

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

fun describe( e : exception ) : string
  if e.message.contains("certificate") || e.message.contains("CERT") || e.message.contains("verif") || e.message.contains("issuer")
  then "certificate rejected" else "error"

fun main()
  val config = tls-server-config(server-cert, server-key)
  // a raw TLS echo server
  val server = tcp-listen("127.0.0.1", 0)
  val port = server.local-port
  val big = "abcdefghij".repeat(30000)
  val echoed = firstof({ server.serve(fn(conn) { val s = conn.tls-accept(config); s.write-all(s.read-all); s.close-notify }); [] }) {
    fun echo( text : string ) : <async,exn,net> string
      with s = tls-connect("localhost", port, ca = ca-cert)
      s.write-text(text)
      s.close-notify
      s.read-all-text
    [ echo("hello over tls"),
      (echo(big) == big).show,
      catch(describe, { tls-connect("localhost", port) fn(s : net-stream) s.read-all-text }) ]
  }
  echoed.foreach(println)
  server.close
  // https with http-serve
  val hsrv = tcp-listen("127.0.0.1", 0)
  val base = "https://localhost:" ++ hsrv.local-port.show
  fun route( req : http-request ) : <async,exn,ndet> http-response
    text-response(200, req.method ++ " " ++ req.target ++ " " ++ req.body-text)
  val results = firstof({ http-serve(hsrv, route, tls = Just(config)); [] }) {
    val r1 = http-get(base ++ "/hello", tls-ca = ca-cert)
    // a plain http client cannot talk to the https server, and the server survives it
    val r2 = catch(fn(_) "plain http failed", { http-get("http://localhost:" ++ hsrv.local-port.show ++ "/").status.show })
    val r3 = http-post(base ++ "/post", "data".bytes, tls-ca = ca-cert)
    // keep-alive over TLS: two requests on one connection
    val pipelined = tls-connect("localhost", hsrv.local-port, ca = ca-cert) fn(s : net-stream)
      s.write-text("GET /one HTTP/1.1\r\nHost: x\r\n\r\nGET /two HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      s.read-all-text
    [ r1.status.show ++ " " ++ r1.body-text, r2, r3.status.show ++ " " ++ r3.body-text,
      "responses: " ++ (pipelined.split("HTTP/1.1 200 OK").length - 1).show
        ++ ", " ++ pipelined.contains("GET /one").show ++ ", " ++ pipelined.contains("GET /two").show ]
  }
  results.foreach(println)
  hsrv.close
  // invalid configurations are rejected
  println(catch(fn(e) e.message.starts-with("tls server config").is-just.show, { tls-server-config("junk", "junk"); "accepted" }))
  println(catch(fn(e) e.message.starts-with("tls server config").is-just.show, { tls-server-config(server-cert, "junk"); "accepted" }))

/* The test certificates were made with:

   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem -days 36500 \
     -subj "/CN=Koka Test CA" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign"
   openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout server.key -out server.csr -subj "/CN=localhost"
   printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n" > ext.cnf
   openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 36500 -extfile ext.cnf
*/
