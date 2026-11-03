// HTTP/2 between the client and server of std/async/os/http: h2c (prior
// knowledge) and TLS (ALPN), multiplexing, flow control, client
// certificates, and reconnecting after the server closes an idle connection.
// The certificates are the ones of tls2.kk and tls3.kk.
import std/async
import std/async/os/net
import std/async/os/tls
import std/async/os/http
import std/time/duration

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

val big = "0123456789abcdef".repeat(100000)   // 1.6 MB: more than the flow control windows

fun route( req : http-request ) : <async,exn,ndet> http-response
  match req.path
    "/big"      -> text-response(200, big)
    "/echo"     -> bytes-response(200, req.body, "application/octet-stream")
    "/fail"     -> throw("handler failed")
    "/redirect" -> text-response(302, "", [("Location", "/peer")])
    "/cert"     -> text-response(200, if req.client-cert.is-empty then "none" else req.client-cert)
    _           -> text-response(200, req.version ++ " " ++ req.method ++ " " ++ req.path ++ " " ++ req.peer)

// the number of distinct connections (peers) in a list of response texts "... peer"
fun connections( bodies : list<string> ) : int
  bodies.map(fn(b) b.split(" ").last.default("")).foldl([], fn(seen, p) if seen.any(fn(q) q == p) then seen else Cons(p, seen)).length

fun main()
  // --- h2c ---
  val server = tcp-listen("127.0.0.1", 0)
  val base = "http://127.0.0.1:" ++ server.local-port.show
  val r1 = firstof({ http-serve(server, route, idle-timeout = 300.milli-seconds); [] }) {
    with client = http-client(h2c = True)
    val seq = [client.http-get(base ++ "/peer"), client.http-get(base ++ "/peer"), client.http-post(base ++ "/peer", "x".bytes)]
    val par = interleaved(list(1, 8).map(fn(i) fn() client.http-get(base ++ "/peer" ++ i.show)))
    val down = client.http-get(base ++ "/big")
    val up = client.http-post(base ++ "/echo", big.bytes)
    val ups = interleaved(list(1, 3).map(fn(_) fn() client.http-post(base ++ "/echo", big.bytes).body.length))
    val failed = client.http-get(base ++ "/fail")
    val redirected = client.http-get(base ++ "/redirect")
    val head = client.http-request("HEAD", base ++ "/peer")
    // the server closes the connection after its idle timeout; the next request uses a new one
    val before = client.http-get(base ++ "/peer").body-text
    wait(700.milli-seconds)
    val after = client.http-get(base ++ "/peer")
    [ "versions: " ++ seq.map(fn(r) r.version).join(", ") ++ " on " ++ seq.map(body-text).connections.show ++ " connection(s)",
      "multiplexed: " ++ par.length.show ++ " responses on " ++ (par ++ seq).map(body-text).connections.show ++ " connection(s)",
      "download: " ++ (down.body-text == big).show ++ ", upload: " ++ (up.body-text == big).show ++ ", concurrent uploads: " ++ ups.show,
      "exception: " ++ failed.status.show ++ " " ++ failed.body-text,
      "redirect: " ++ redirected.status.show ++ " " ++ redirected.body-text.split(" ").take(3).join(" "),
      "head: " ++ head.status.show ++ " " ++ head.body.length.show,
      "after the idle timeout: " ++ after.status.show ++ " " ++ after.version ++ ", new connection: " ++ ([before, after.body-text].connections == 2).show ]
  }
  r1.foreach(println)
  // plain requests (without a client) still use HTTP/1.1
  val r2 = firstof({ http-serve(server, route); "" }) { http-get(base ++ "/peer").version }
  println("plain request: " ++ r2)
  server.close
  // --- TLS with ALPN, and a client certificate ---
  val config = tls-server-config(server-cert, server-key, client-ca = client-ca, client-cert-required = False, alpn = ["h2", "http/1.1"])
  val tserver = tcp-listen("127.0.0.1", 0)
  val tbase = "https://localhost:" ++ tserver.local-port.show
  val r3 = firstof({ http-serve(tserver, route, tls = Just(config)); [] }) {
    with h2 = http-client(tls-ca = ca-cert, tls-cert = client-cert, tls-key = client-key)
    with h1 = http-client(tls-ca = ca-cert, http2 = False)
    val par = interleaved(list(1, 4).map(fn(i) fn() h2.http-get(tbase ++ "/peer" ++ i.show)))
    [ "tls: " ++ par.map(fn(r) r.version).join(", ") ++ " on " ++ par.map(body-text).connections.show ++ " connection(s)",
      "client certificate: " ++ h2.http-get(tbase ++ "/cert").body-text,
      "download: " ++ (h2.http-get(tbase ++ "/big").body-text == big).show,
      "without http2: " ++ h1.http-get(tbase ++ "/peer").version ++ ", client certificate: " ++ h1.http-get(tbase ++ "/cert").body-text ]
  }
  r3.foreach(println)
  tserver.close
