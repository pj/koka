// TLS client certificates and ALPN; no internet needed.
// The server certificates are the ones from tls2.kk; the client certificates
// are valid until 2126 (see the end of this file for how they were made).
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

val client-ca = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBpDCCAUmgAwIBAgIUQbAoRnLqkxG84Z90h/fjkn6B4tEwCgYIKoZIzj0EAwIw\n"
  ++ "HjEcMBoGA1UEAwwTS29rYSBUZXN0IENsaWVudCBDQTAgFw0yNjExMDMyMTQzMDJa\n"
  ++ "GA8yMTI2MTAxMDIxNDMwMlowHjEcMBoGA1UEAwwTS29rYSBUZXN0IENsaWVudCBD\n"
  ++ "QTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABAP4vkGWVrWJKLbl8sN2rC85YxwH\n"
  ++ "nE2jmHmWLik5sj90Cw87J5yBHqfp8V8vsn9wHxMyedJrC38izcL9IBdcRrKjYzBh\n"
  ++ "MB0GA1UdDgQWBBS8As7lxiPzp+lYcfg9NsjKPxa4JjAfBgNVHSMEGDAWgBS8As7l\n"
  ++ "xiPzp+lYcfg9NsjKPxa4JjAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIC\n"
  ++ "BDAKBggqhkjOPQQDAgNJADBGAiEAv3RdMRa9Dau5cq0eIGeSXjmaoMu9ArgOfjBi\n"
  ++ "h8D9M5sCIQDdLCgHK3v/wFPyZs8kHxImPkUGIoS1+QflTEJq6xNtEQ==\n"
  ++ "-----END CERTIFICATE-----\n"

val client-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBrDCCAVKgAwIBAgIUcL4cUwU/Do6PvwDz6vQg05Z0azswCgYIKoZIzj0EAwIw\n"
  ++ "HjEcMBoGA1UEAwwTS29rYSBUZXN0IENsaWVudCBDQTAgFw0yNjExMDMyMTQzMDJa\n"
  ++ "GA8yMTI2MTAxMDIxNDMwMlowGzEZMBcGA1UEAwwQS29rYSBUZXN0IENsaWVudDBZ\n"
  ++ "MBMGByqGSM49AgEGCCqGSM49AwEHA0IABMcuMGwixFZNuqExIX3QyuID8/z9YWrL\n"
  ++ "V4JY+YikITrifvMzn7hgrdlz+LAvCB2Y9+luqVJbywFwLov33lOtMiWjbzBtMAkG\n"
  ++ "A1UdEwQCMAAwCwYDVR0PBAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMCMB0GA1Ud\n"
  ++ "DgQWBBS9eGDMKMALZLTP797eTuJI/auGCjAfBgNVHSMEGDAWgBS8As7lxiPzp+lY\n"
  ++ "cfg9NsjKPxa4JjAKBggqhkjOPQQDAgNIADBFAiB6C0AP926S738RtV53bMfVnyL0\n"
  ++ "2CFICDI7IzPkhMYHyQIhAJQah0t8AHM9+x+ainAwgAy8RTfsR7lGCojGR1nfb6/7\n"
  ++ "-----END CERTIFICATE-----\n"

val client-key = "-----BEGIN PRIVATE KEY-----\n"
  ++ "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgSQ77ZcUXiVIVz3Mv\n"
  ++ "LymQfj7C/KN/ppV1E2gvoorWs3mhRANCAATHLjBsIsRWTbqhMSF90MriA/P8/WFq\n"
  ++ "y1eCWPmIpCE64n7zM5+4YK3Zc/iwLwgdmPfpbqlSW8sBcC6L995TrTIl\n"
  ++ "-----END PRIVATE KEY-----\n"

val rogue-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBmTCCAUCgAwIBAgIUSxKKi7h3MubaO8+owX0iC9/RAkswCgYIKoZIzj0EAwIw\n"
  ++ "FzEVMBMGA1UEAwwMUm9ndWUgQ2xpZW50MCAXDTI2MTEwMzIxNDMwMloYDzIxMjYx\n"
  ++ "MDEwMjE0MzAyWjAXMRUwEwYDVQQDDAxSb2d1ZSBDbGllbnQwWTATBgcqhkjOPQIB\n"
  ++ "BggqhkjOPQMBBwNCAAQaszZqHMfurYByjLvxBHXWZSTODfpCn14jJChzUMbWw2d9\n"
  ++ "sHJIL1H+H+Ts5lYEK1ftw2fPq75E7AB/6tllqBquo2gwZjAdBgNVHQ4EFgQUuuwk\n"
  ++ "kl2c8G1FAgPgR8XHW3/RoyswHwYDVR0jBBgwFoAUuuwkkl2c8G1FAgPgR8XHW3/R\n"
  ++ "oyswDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUEDDAKBggrBgEFBQcDAjAKBggqhkjO\n"
  ++ "PQQDAgNHADBEAiA3oGaq72WMMMQF5YbCMY6QRPvp3n4Uo5k+A+Uz/Mp2sAIgUA5d\n"
  ++ "o+TvuIsEoMpGI984zRDkDnUMI8Xd5i13HDBlQp0=\n"
  ++ "-----END CERTIFICATE-----\n"

val rogue-key = "-----BEGIN PRIVATE KEY-----\n"
  ++ "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgh+S2kgTbQbBk3Azw\n"
  ++ "J1PDHeHIB8ist1F7okRC3gNDYLahRANCAAQaszZqHMfurYByjLvxBHXWZSTODfpC\n"
  ++ "n14jJChzUMbWw2d9sHJIL1H+H+Ts5lYEK1ftw2fPq75E7AB/6tllqBqu\n"
  ++ "-----END PRIVATE KEY-----\n"

// the server answers with what it knows about the client
fun hello( conn : tcp-socket, config : tls-config ) : <async,exn> ()
  val s = conn.tls-accept(config)
  s.write-text("client: " ++ s.peer-certificate.default("none") ++ ", protocol: " ++ s.alpn-protocol.default("none"))
  s.close-notify

fun ask( port : int, cert : string = "", key : string = "", alpn : list<string> = [] ) : <async,exn,net> string
  catch(fn(_) "rejected") fn()
    with s = tls-connect("localhost", port, ca = ca-cert, cert = cert, key = key, alpn = alpn)
    val text = s.read-all-text
    if text.is-empty then "rejected" else text ++ " | server: " ++ s.peer-certificate.default("none")

fun with-server( config : tls-config, action : int -> <async,exn,net,ndet> list<string> ) : <async,exn,net,ndet> list<string>
  val server = tcp-listen("127.0.0.1", 0)
  val port = server.local-port
  val res = firstof({ server.serve(fn(conn) hello(conn, config)); [] }) { action(port) }
  server.close
  res

fun main()
  // client certificates required
  val required = tls-server-config(server-cert, server-key, client-ca = client-ca)
  with-server(required) fn(port)
    [ "required, with cert: " ++ ask(port, client-cert, client-key),
      "required, without cert: " ++ ask(port),
      "required, untrusted cert: " ++ ask(port, rogue-cert, rogue-key) ]
  .foreach(println)
  // client certificates optional
  val optional = tls-server-config(server-cert, server-key, client-ca = client-ca, client-cert-required = False)
  with-server(optional) fn(port)
    [ "optional, with cert: " ++ ask(port, client-cert, client-key),
      "optional, without cert: " ++ ask(port),
      "optional, untrusted cert: " ++ ask(port, rogue-cert, rogue-key) ]
  .foreach(println)
  // ALPN
  val alpn = tls-server-config(server-cert, server-key, alpn = ["h2", "http/1.1"])
  with-server(alpn) fn(port)
    [ "alpn h2: " ++ ask(port, alpn = ["h2", "http/1.1"]),
      "alpn http/1.1: " ++ ask(port, alpn = ["http/1.1"]),
      "alpn none: " ++ ask(port) ]
  .foreach(println)
  // invalid settings
  val listener = tcp-listen("127.0.0.1", 0)
  println(catch(fn(e) "invalid client key: failed", { tls-connect("localhost", listener.local-port, ca = ca-cert, cert = client-cert, key = "junk").close; "accepted" }))
  listener.close
  println(catch(fn(e) e.message.starts-with("tls server config").is-just.show, { tls-server-config(server-cert, server-key, client-ca = "junk"); "accepted" }))
  // https with a client certificate
  val hsrv = tcp-listen("127.0.0.1", 0)
  val base = "https://localhost:" ++ hsrv.local-port.show
  fun route( req : http-request ) : <async,exn,ndet> http-response
    text-response(200, "client: " ++ (if req.client-cert.is-empty then "none" else req.client-cert))
  val results = firstof({ http-serve(hsrv, route, tls = Just(optional)); [] }) {
    with client = http-client(tls-ca = ca-cert, tls-cert = client-cert, tls-key = client-key)
    [ http-get(base ++ "/", tls-ca = ca-cert, tls-cert = client-cert, tls-key = client-key).body-text,
      http-get(base ++ "/", tls-ca = ca-cert).body-text,
      client.http-get(base ++ "/").body-text ]
  }
  results.foreach(fn(r) println("https " ++ r))
  hsrv.close

/* The client certificates were made with:

   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout client-ca.key -out client-ca.pem -days 36500 \
     -subj "/CN=Koka Test Client CA" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign"
   openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout client.key -out client.csr -subj "/CN=Koka Test Client"
   printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n" > client-ext.cnf
   openssl x509 -req -in client.csr -CA client-ca.pem -CAkey client-ca.key -CAcreateserial -out client.pem -days 36500 -extfile client-ext.cnf
   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout rogue.key -out rogue.pem -days 36500 \
     -subj "/CN=Rogue Client" -addext "extendedKeyUsage=clientAuth"
*/
