// TLS certificate revocation lists, for server and client certificates.
// Test certificates and the CRL are valid until 2126 (see the end).
import std/async
import std/async/os/net
import std/async/os/tls

val ca-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBnTCCAUOgAwIBAgIUfBlo3yY4LyakYniNyVqihlIsPoIwCgYIKoZIzj0EAwIw\n"
  ++ "GzEZMBcGA1UEAwwQS29rYSBDUkwgVGVzdCBDQTAgFw0yNjExMDkwNDE4MTFaGA8y\n"
  ++ "MTI2MTAxNjA0MTgxMVowGzEZMBcGA1UEAwwQS29rYSBDUkwgVGVzdCBDQTBZMBMG\n"
  ++ "ByqGSM49AgEGCCqGSM49AwEHA0IABJQ0yoR0fRHirdG8bd0+HBo/u90q+utssn0G\n"
  ++ "9+9L02T4exj+bOv/WSvC0k+SK8JBsSsgxGp+kaZCpSHqyymnFPSjYzBhMB0GA1Ud\n"
  ++ "DgQWBBSM7PthQvqDGp8r6Zmr8S5ieoWLkDAfBgNVHSMEGDAWgBSM7PthQvqDGp8r\n"
  ++ "6Zmr8S5ieoWLkDAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAKBggq\n"
  ++ "hkjOPQQDAgNIADBFAiEAkD/rPaOfXsWE5PqXGSyXBbSj3x0ShnXN8kaC48xYpzwC\n"
  ++ "ICXEmRNdG77uKfTGQW4LOFUyIpYsUc+zNsU7+xqQxwoE\n"
  ++ "-----END CERTIFICATE-----\n"

val crl = "-----BEGIN X509 CRL-----\n"
  ++ "MIHiMIGJAgEBMAoGCCqGSM49BAMCMBsxGTAXBgNVBAMMEEtva2EgQ1JMIFRlc3Qg\n"
  ++ "Q0EXDTI2MTEwOTA0MTgxMVoYDzIxMjYxMDE2MDQxODExWjAqMBMCAhABFw0yNjEx\n"
  ++ "MDkwNDE4MTFaMBMCAhADFw0yNjExMDkwNDE4MTFaoA8wDTALBgNVHRQEBAICEAAw\n"
  ++ "CgYIKoZIzj0EAwIDSAAwRQIhAPdd82xP9HOKaXXXM9acE06qnHYJRgKkxAVo6vXi\n"
  ++ "klA6AiBN7q4qZSLKoe6gJO6i6g2fvyJt8L3CjFBxu8I0adLLqw==\n"
  ++ "-----END X509 CRL-----\n"

val good-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBqDCCAU+gAwIBAgICEAAwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQS29rYSBD\n"
  ++ "UkwgVGVzdCBDQTAgFw0yNjExMDkwNDE4MTFaGA8yMTI2MTAxNjA0MTgxMVowDzEN\n"
  ++ "MAsGA1UEAwwEZ29vZDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABEl9Wu0O99ji\n"
  ++ "8B37zNiWvnnHm9O4CPRceXWycEMrDOQVj6FVJfmza/mjZMV4Ntif9aTkDERgjwtk\n"
  ++ "nKoyL78hNnSjgYwwgYkwGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMAkGA1Ud\n"
  ++ "EwQCMAAwCwYDVR0PBAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMB0GA1UdDgQW\n"
  ++ "BBTtdx2i8awnpqZ6fMPKF/zl6GguOjAfBgNVHSMEGDAWgBSM7PthQvqDGp8r6Zmr\n"
  ++ "8S5ieoWLkDAKBggqhkjOPQQDAgNHADBEAiAXTsFu2cm13T32GmX/aUdMAHJaX7DQ\n"
  ++ "pdEguc1IzwnsagIgf8imyuOgcnMrgpW8PKEOUnAF5onI4pk63jrIFyKgCTo=\n"
  ++ "-----END CERTIFICATE-----\n"

val good-key = "-----BEGIN PRIVATE KEY-----\n"
  ++ "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgfAQi5GdtFtceHaqR\n"
  ++ "aNFtmxnhI5UsvO6IHbmHErSyDSWhRANCAARJfVrtDvfY4vAd+8zYlr55x5vTuAj0\n"
  ++ "XHl1snBDKwzkFY+hVSX5s2v5o2TFeDbYn/Wk5AxEYI8LZJyqMi+/ITZ0\n"
  ++ "-----END PRIVATE KEY-----\n"

val revoked-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBrDCCAVKgAwIBAgICEAEwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQS29rYSBD\n"
  ++ "UkwgVGVzdCBDQTAgFw0yNjExMDkwNDE4MTFaGA8yMTI2MTAxNjA0MTgxMVowEjEQ\n"
  ++ "MA4GA1UEAwwHcmV2b2tlZDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABLGKHluW\n"
  ++ "H2GXTRgZnxaPLvgtBoKXzUMaa3UX4U3lmOpgvrZ0WTbaIIJ20XUfbhRrYaQZnyTO\n"
  ++ "lca43mZ5439yN16jgYwwgYkwGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMAkG\n"
  ++ "A1UdEwQCMAAwCwYDVR0PBAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMB0GA1Ud\n"
  ++ "DgQWBBRuOFsICDRQMl47rfph+aDuGXBkmjAfBgNVHSMEGDAWgBSM7PthQvqDGp8r\n"
  ++ "6Zmr8S5ieoWLkDAKBggqhkjOPQQDAgNIADBFAiBxMnk38gjXyfhb0QVVEq0Bqvea\n"
  ++ "8KDBcLOXkLJ2dxHsmwIhAOJB1x5xUrL3ha3np0BfxC812sRG/4Id3CopNS0n1rUA\n"
  ++ "-----END CERTIFICATE-----\n"

val revoked-key = "-----BEGIN PRIVATE KEY-----\n"
  ++ "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgTor1w2LytIVrkBwn\n"
  ++ "kMqOOSe2U/vwqpzCt6gvsp2N6fihRANCAASxih5blh9hl00YGZ8Wjy74LQaCl81D\n"
  ++ "Gmt1F+FN5ZjqYL62dFk22iCCdtF1H24Ua2GkGZ8kzpXGuN5meeN/cjde\n"
  ++ "-----END PRIVATE KEY-----\n"

val client-good-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBkjCCATigAwIBAgICEAIwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQS29rYSBD\n"
  ++ "UkwgVGVzdCBDQTAgFw0yNjExMDkwNDE4MTFaGA8yMTI2MTAxNjA0MTgxMVowFjEU\n"
  ++ "MBIGA1UEAwwLY2xpZW50LWdvb2QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAS7\n"
  ++ "JpLxmf/Adq8et7IyGeix9kRytO7I8eGRcj5mtIJbyjmCWcqFbE5MBb8lwEFgiyPK\n"
  ++ "Maf+dNRKZWIQEPFOJfG0o28wbTAJBgNVHRMEAjAAMAsGA1UdDwQEAwIHgDATBgNV\n"
  ++ "HSUEDDAKBggrBgEFBQcDAjAdBgNVHQ4EFgQUhKj6ZPIlmmpToGVC4I8ytdOezH4w\n"
  ++ "HwYDVR0jBBgwFoAUjOz7YUL6gxqfK+mZq/EuYnqFi5AwCgYIKoZIzj0EAwIDSAAw\n"
  ++ "RQIgaiJkX0vuvFyQHMFe591OnBuV7NFFKs1nPCI2v68fbU8CIQDt2+yHZCU+qmPw\n"
  ++ "fLiMoVKSSH2YCVW8TKSVf14rifY8mQ==\n"
  ++ "-----END CERTIFICATE-----\n"

val client-good-key = "-----BEGIN PRIVATE KEY-----\n"
  ++ "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgSeKN4s16BXbdEg9w\n"
  ++ "0dg531jRA8Xkp9B/Z+7LGyqiOAKhRANCAAS7JpLxmf/Adq8et7IyGeix9kRytO7I\n"
  ++ "8eGRcj5mtIJbyjmCWcqFbE5MBb8lwEFgiyPKMaf+dNRKZWIQEPFOJfG0\n"
  ++ "-----END PRIVATE KEY-----\n"

val client-revoked-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBlTCCATugAwIBAgICEAMwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQS29rYSBD\n"
  ++ "UkwgVGVzdCBDQTAgFw0yNjExMDkwNDE4MTFaGA8yMTI2MTAxNjA0MTgxMVowGTEX\n"
  ++ "MBUGA1UEAwwOY2xpZW50LXJldm9rZWQwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC\n"
  ++ "AARewTWdKvPxmZIDsDn24rFkcUX+vUgeTsOTUvkyus9clA+gHPbTq7TUzcv9vZJs\n"
  ++ "0C/pzfYCd16rMfUFZmpd07gKo28wbTAJBgNVHRMEAjAAMAsGA1UdDwQEAwIHgDAT\n"
  ++ "BgNVHSUEDDAKBggrBgEFBQcDAjAdBgNVHQ4EFgQUSXwj+G0+ofBLlAt6JOqf4I+h\n"
  ++ "nDwwHwYDVR0jBBgwFoAUjOz7YUL6gxqfK+mZq/EuYnqFi5AwCgYIKoZIzj0EAwID\n"
  ++ "SAAwRQIgWqzueMs1W7+JlOAJtHYazlmWezeAlFKi58gvcNjvpKACIQC01nQeZqP/\n"
  ++ "ui37wWRi7U7TkuDCy3Cz+dMtFVKgqfV0Qg==\n"
  ++ "-----END CERTIFICATE-----\n"

val client-revoked-key = "-----BEGIN PRIVATE KEY-----\n"
  ++ "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgstLIelpHPdLz9h5a\n"
  ++ "Bw4bzLQJhIv09ZaGuNvZFkN+FNehRANCAARewTWdKvPxmZIDsDn24rFkcUX+vUge\n"
  ++ "TsOTUvkyus9clA+gHPbTq7TUzcv9vZJs0C/pzfYCd16rMfUFZmpd07gK\n"
  ++ "-----END PRIVATE KEY-----\n"

fun outcome( action : () -> <async,exn,net> string ) : <async,net> string
  catch(fn(e) "rejected" ++ (if e.message.to-lower.contains("revoked") then " (revoked)" else ""), action)

// Serve one connection with `config`, and connect to it as a client.
fun attempt( config : tls-config, client : (int) -> <async,exn,net> string ) : <async,exn,net,ndet> string
  val srv = tcp-listen("127.0.0.1", 0)
  val port = srv.local-port
  val (_, res) = interleaved({
    catch(fn(_) (), {
      with conn = srv.accept
      val s = conn.tls-accept(config)
      s.write-text("ok")
      s.close-notify
    })
  }, {
    outcome { client(port) }
  })
  srv.close
  res

// The server's answer; with TLS 1.3 a client learns that the server rejected
// its certificate only when the connection is closed instead.
fun read-ok( s : net-stream ) : <async,exn> string
  val answer = s.read.string
  if answer != "ok" then throw("the server closed the connection")
  answer

fun main()
  val good = tls-server-config(good-cert, good-key)
  val revoked = tls-server-config(revoked-cert, revoked-key)
  // the client checks the server certificate against the CRL
  println("good, no CRL: " ++ attempt(good, fn(p) tls-connect("localhost", p, read-ok, ca = ca-cert)))
  println("good, CRL: " ++ attempt(good, fn(p) tls-connect("localhost", p, read-ok, ca = ca-cert, crl = crl)))
  println("revoked, no CRL: " ++ attempt(revoked, fn(p) tls-connect("localhost", p, read-ok, ca = ca-cert)))
  println("revoked, CRL: " ++ attempt(revoked, fn(p) tls-connect("localhost", p, read-ok, ca = ca-cert, crl = crl)))
  // the server checks client certificates against its CRL
  val mutual = tls-server-config(good-cert, good-key, client-ca = ca-cert, client-crl = crl)
  println("client good: " ++ attempt(mutual, fn(p) tls-connect("localhost", p, read-ok, ca = ca-cert, cert = client-good-cert, key = client-good-key)))
  println("client revoked: " ++ attempt(mutual, fn(p) tls-connect("localhost", p, read-ok, ca = ca-cert, cert = client-revoked-cert, key = client-revoked-key)))
  // an invalid CRL is reported
  println(outcome { tls-connect("localhost", 1, read-ok, ca = ca-cert, crl = "junk") })

/* Made with openssl: a CA (with cRLSign), server certificates "good" and "revoked"
   (DNS:localhost, IP:127.0.0.1) and client certificates "client-good" and
   "client-revoked", issued with `openssl ca`; then
   `openssl ca -revoke revoked.pem`, `openssl ca -revoke client-revoked.pem` and
   `openssl ca -gencrl -out ca.crl` (default_crl_days = 36500).
*/
