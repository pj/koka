// std/async/os/ocsp and std/crypto/x509: OCSP requests and responses
// (fixtures made with `openssl ocsp`, see the end of this file)
import std/async
import std/async/os/net
import std/async/os/http
import std/async/os/tls
import std/async/os/ocsp
import std/crypto/x509
import std/text/encoding

fun b64( s : string ) : bytes
  base64-decode(s).default(bytes/empty)

fun cert( pem : string ) : exn certificate
  match x509-pem(pem)
    Cons(c, _) -> c
    Nil -> throw("no certificate")

fun bytes/(==)( a : bytes, b : bytes ) : bool
  base64-encode(a) == base64-encode(b)

fun show-result( r : error<ocsp-status> ) : string
  match r
    Ok(s) -> s.show
    Error(e) -> "error: " ++ e.message

fun main()
  val ca = cert(ca-pem)
  val good = cert(good-pem)
  val revoked = cert(revoked-pem)
  val other = cert(other-pem)
  val responder = cert(responder-pem)
  // certificates
  println((good.subject-name, good.issuer-name, ca.subject-name))
  println((good.is-signed-by(ca), ca.is-signed-by(ca), good.is-signed-by(good)))
  println((good.ocsp-urls, ca.ocsp-urls))
  println((responder.extended-key-usage, good.extended-key-usage))
  // the request is the same as openssl's (without a nonce)
  println(ocsp-request(good, ca) == b64(req-good))
  println(ocsp-request(good, ca, nonce = "0123456789abcdef".bytes).length > b64(req-good).length)
  // responses signed by the CA (RSA) and by a responder it authorized (ECDSA)
  [("good", good, resp-good-ca, resp-good-delegated), ("revoked", revoked, resp-revoked-ca, resp-revoked-delegated),
   ("other", other, resp-other-ca, resp-other-delegated)].foreach fn((name, c, by-ca, by-responder))
    println((name, try({ ocsp-status(b64(by-ca), c, ca) }).show-result, try({ ocsp-status(b64(by-responder), c, ca) }).show-result))
  // rejected responses
  println(try({ ocsp-status(b64(resp-good-unauthorized), good, ca) }).show-result)
  // a byte of the signed response data changed
  val orig = b64(resp-good-ca)
  val tampered = orig.subbytes(0, 70) ++ vector([(orig[70] + 1) % 256]).bytes ++ orig.subbytes(71)
  println(try({ ocsp-status(tampered, good, ca) }).show-result)
  println(try({ ocsp-status(b64(resp-good-ca), revoked, ca) }).show-result)
  println(try({ ocsp-status(b64(resp-good-ca), good, ca, now = 0) }).show-result)
  println(try({ ocsp-status(b64(resp-good-ca), good, ca, now = 7258118400) }).show-result)   // in 2200
  println(try({ ocsp-status("not der".bytes, good, ca) }).show-result)
  println(try({ ocsp-status(b64(error-response), good, ca) }).show-result)

  // over HTTP, from a local responder that answers for the CA
  val server = tcp-listen("127.0.0.1", 0)
  val url = "http://127.0.0.1:" ++ server.local-port.show ++ "/"
  firstof({ http-serve(server, fn(req) answer(req)) }, {
    println(("http", ocsp-check(good, ca, url).show, ocsp-check(revoked, ca, url).show, ocsp-check(other, ca, url).show))
    println(try({ ocsp-check(good, ca, url ++ "missing") }).show-result)
    println(try({ ocsp-check(ca, ca) }).show-result)
  })
  server.close

  // TLS: the chain a server presents, and tls-connect(ocsp = True) with the
  // responder the certificates name (on a fixed port)
  val responder-server = tcp-listen("127.0.0.1", 47321)
  val tserver = tcp-listen("127.0.0.1", 0)
  val tport = tserver.local-port
  val config = tls-server-config(local-good-pem ++ "\n" ++ ca-pem, local-good-key, sni = [("local-revoked", local-revoked-pem, local-revoked-key)])
  firstof({ http-serve(responder-server, answer) }, {
    firstof({ tserver.serve(fn(conn) { val s = conn.tls-accept(config); s.write-all("hello".bytes); s.close-notify }) }, {
      val chain = tls-connect("127.0.0.1", tport, ca = ca-pem, server-name = "local-good", action = fn(s) s.peer-chain.map(subject-name))
      println(("chain", chain))
      println(("ocsp good", tls-connect("127.0.0.1", tport, ca = ca-pem, server-name = "local-good", ocsp = True, action = fn(s) s.read-all.string)))
      val revoked-result = try({ tls-connect("127.0.0.1", tport, ca = ca-pem, server-name = "local-revoked", ocsp = True, action = fn(s) s.read-all.string) })
      println(("ocsp revoked", match revoked-result { Ok(t) -> t; Error(e) -> e.message }))
      println(("without ocsp", tls-connect("127.0.0.1", tport, ca = ca-pem, server-name = "local-revoked", action = fn(s) s.read-all.string)))
    })
  })
  responder-server.close
  tserver.close

fun answer( req : http-request ) : <async,exn,ndet> http-response
  if req.path != "/" || req.header("Content-Type") != Just("application/ocsp-request") then text-response(404, "no")
  else
    val table = [(req-good, resp-good-ca), (req-revoked, resp-revoked-delegated), (req-other, resp-other-ca),
                 (req-local-good, resp-local-good-ca), (req-local-revoked, resp-local-revoked-ca)]
    val resp = table.find(fn((q, _)) req.body == b64(q)).map(snd).default(error-response)
    bytes-response(200, b64(resp), "application/ocsp-response")

// an OCSPResponse with status 1 (malformed request)
val error-response = "MAMKAQE="
val ca-pem = "-----BEGIN CERTIFICATE-----\nMIIDITCCAgmgAwIBAgIUR5SRFSyFscLhhCZDPMWaGJ4zbSkwDQYJKoZIhvcNAQEL\nBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIx\nMjYxMDE2MTk0OTU2WjAXMRUwEwYDVQQDDAxUZXN0IE9DU1AgQ0EwggEiMA0GCSqG\nSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC/AEEKpd+VsMDaEDEHbaPCz/91mDzO7Ckb\nu2ZFB22OTOkWhmcbFf3Q8q5AU/abd7kmsnAFyzhWgnb/LMWZBL48spbaKvdXTy3x\nty/SWh4RvybWK803AI0CN5qq19miYZ8oP+R86GZgOzsl703JcnfLMo5o7r8aLyku\nN7/ac0zOhQogt6SbzIBeoBvfJSkBH9AQqydO2wIkWVfLQYlP0dwUMuNmLRENgZkM\nDsyGmtytJsAGWFjVvIhxtnZPLvrmOAStr4poWsUgkBp8n/KwDgs67i7TtrNr1r9c\nkcSIbMamE7DPTKhlVPPapD1shGK5Qt55M97hakGJAAkdTd0JHdwvAgMBAAGjYzBh\nMB0GA1UdDgQWBBQC+XCq9iTV+WLaN6BMQ+B/KydYijAfBgNVHSMEGDAWgBQC+XCq\n9iTV+WLaN6BMQ+B/KydYijAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIB\nBjANBgkqhkiG9w0BAQsFAAOCAQEAlCRZeGjlNf+EFvkbuMbP57ImrxQq3V4wAOin\nYNWy1CZRryqs0Nrgd1ft8b5EGmY0IrXxcsJEvAt9aGAWboLlQjcotjv9RF4MWixD\nnZyYuW2RXYUxvLDm5FI1sp4xEiWmec6MFuXc/Jkf/1EW7ttHqhmAxPzeV6072oS+\nGNzhiGJo7rBqzF8iPcOiSueILbpOrX22jr1TVlzOvOzpCNxXX5LlhBWG+YzZHAbS\nL03MIALUUIOZqth6tjRtcdD2HOIYfkVzwS85mprxtLRj+YQH+BkG2zxFGdPr2NyZ\nlOGuIvwcnEZCSmv4ML65bfSMOVXFWcvsLXYwmIkKpf3mUPQ9tA==\n-----END CERTIFICATE-----"
val good-pem = "-----BEGIN CERTIFICATE-----\nMIICbzCCAVegAwIBAgIUUotxmzg/Zom9grnKO0xzgElTPaswDQYJKoZIhvcNAQEL\nBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIx\nMjYxMDE2MTk0OTU2WjAPMQ0wCwYDVQQDDARnb29kMFkwEwYHKoZIzj0CAQYIKoZI\nzj0DAQcDQgAEANEOaQ1Y3eBgMipRFm0wKPJrS/4jttz9BcUfqh4Cs31Hk0zqbXYD\nPs8OnxD/Z9KB5+2gWS9cZ5X29f/jpD/USaOBgzCBgDAtBggrBgEFBQcBAQQhMB8w\nHQYIKwYBBQUHMAGGEWh0dHA6Ly9vY3NwLnRlc3QvMA8GA1UdEQQIMAaCBGdvb2Qw\nHQYDVR0OBBYEFDCak/QJVQB11188Fy+Uwu5UWPFuMB8GA1UdIwQYMBaAFAL5cKr2\nJNX5Yto3oExD4H8rJ1iKMA0GCSqGSIb3DQEBCwUAA4IBAQAemTt39qYNk5zyyJYp\nqpPWT+m58lknWulT6XS4ctbsfVkXq2+begHu5AJi93ZTTZ5DkgtgGbX2NU7nc/6z\n7Sz4fT/3tji+Hkr+9kC/njqfn+D5OKG9cG7egbFt3DxLzSFedW1zG5Q9Sqe9yFUb\nm1iOV/ZgUz5w2+RDi7QwHMHtd8E9IA93iwhXGth1k/E5j2DD9qMiRCgkcphstsp3\nHfE3OaRHIYRFulaQfovDlLupZ551KNB7vuUdK7lwCgRSs3eHLL+z6cdEcQsU3i4M\ntJDngY8bj7Nd3bTDeDDjSRDR806uJHKJztUr7dO6RWPTkCUn13M6kwOp+CmTiq1r\nLiAY\n-----END CERTIFICATE-----"
val revoked-pem = "-----BEGIN CERTIFICATE-----\nMIICdTCCAV2gAwIBAgIUUotxmzg/Zom9grnKO0xzgElTPawwDQYJKoZIhvcNAQEL\nBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIx\nMjYxMDE2MTk0OTU2WjASMRAwDgYDVQQDDAdyZXZva2VkMFkwEwYHKoZIzj0CAQYI\nKoZIzj0DAQcDQgAEUHjJCGz2sk0EOKyLdc4/eYjWhut6zCNf3V6r6iHwddYDPAvk\ngg8Xz2Y471r79vqoEHd5rPAYSLsoFtYCF9i7QaOBhjCBgzAtBggrBgEFBQcBAQQh\nMB8wHQYIKwYBBQUHMAGGEWh0dHA6Ly9vY3NwLnRlc3QvMBIGA1UdEQQLMAmCB3Jl\ndm9rZWQwHQYDVR0OBBYEFPx0sVRpDIl6HucQwwmOvur/cMauMB8GA1UdIwQYMBaA\nFAL5cKr2JNX5Yto3oExD4H8rJ1iKMA0GCSqGSIb3DQEBCwUAA4IBAQA49R7Cc+Yu\nrJaYtI8TiXRkZ4OLZswka+ddusXNgTS4y/NHpSIPBiLNaRHsBtVpG1ZcEMJzOQCq\nciajSlW3sdpTwgDeM6/F/zPRh/LKvc6dd223K/KbLdYpLzsa3gO+zuqWe5VhtIqd\n3WITxD4N0PUWdlhjptJNKkOs91ziSxW/7/ShCM4M6wdztmCVv1Y7lnILZaf0oB2j\nlLWQWfrpj6D2EOhPsBi/BgPGWNme+6hs5pkCRY2HXliuQQKhDMP6zTJpknfYVwns\nUCMmn9Flxo58EN1gBHpj00hCiB4HE0fCKOOlIVvNbY3fi2jpyKHtsdg0SevXU11U\nxADWSx+1vcVU\n-----END CERTIFICATE-----"
val other-pem = "-----BEGIN CERTIFICATE-----\nMIICXTCCAUWgAwIBAgIUUotxmzg/Zom9grnKO0xzgElTPa0wDQYJKoZIhvcNAQEL\nBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIx\nMjYxMDE2MTk0OTU2WjAQMQ4wDAYDVQQDDAVvdGhlcjBZMBMGByqGSM49AgEGCCqG\nSM49AwEHA0IABKYrazZ6cGKqHNMKFFk8698z0kZg56Sw1VnoM1vja58yo8HxYgPM\nCWbTsYw6GX7FzND5ZzO35B90HoY4j9TrWhujcTBvMC0GCCsGAQUFBwEBBCEwHzAd\nBggrBgEFBQcwAYYRaHR0cDovL29jc3AudGVzdC8wHQYDVR0OBBYEFKS9BKycSRBQ\n9rF67VsN5IKtvTYAMB8GA1UdIwQYMBaAFAL5cKr2JNX5Yto3oExD4H8rJ1iKMA0G\nCSqGSIb3DQEBCwUAA4IBAQBQnDYHGSqwUIP3huzoqZH2rKVZMKVUQfmWts7S4716\n7IDxnqMlBRFn4bJPAAraV6GxRooA4h0FF1Kv3YEa0wWk3auWSihF3OuCepGuJFfj\nWX9d21IjAk5XSv1TyhOjpm1zGvBsrsG0hKqx+rdKrQCfY4P58d938/YBvv8rpiRn\nM92D3u5OXmO7UDKl3K7JQ/93os84gf2lpLWOBvzr/R4y8G2uml704j1YN/SdEDR6\nrg91cFwanJ9XfQ7dPHpBPuO86XKXRBLtHvavAx5NfhJuUzJ4B1KRqnlOMFyQFBWC\n61k9Y0CaFuRkfJvWqd7dIxg+EYI2GjHZeqXq9FkBnIMM\n-----END CERTIFICATE-----"
val responder-pem = "-----BEGIN CERTIFICATE-----\nMIICRzCCAS+gAwIBAgIUUotxmzg/Zom9grnKO0xzgElTPa4wDQYJKoZIhvcNAQEL\nBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIx\nMjYxMDE2MTk0OTU2WjAUMRIwEAYDVQQDDAlyZXNwb25kZXIwWTATBgcqhkjOPQIB\nBggqhkjOPQMBBwNCAAS07vbunkzrbiTs/ZsJFwXbfHPVu5pAhNTxZiPOLOlTytj+\nrHIjTWImBn85IVTnOlz1OFrjipTN252jnq+6sRy1o1cwVTATBgNVHSUEDDAKBggr\nBgEFBQcDCTAdBgNVHQ4EFgQUp0Z4Int+oxJlDnDWtcZLkCbel4IwHwYDVR0jBBgw\nFoAUAvlwqvYk1fli2jegTEPgfysnWIowDQYJKoZIhvcNAQELBQADggEBAG6+mR3j\nP9S2Y3CvEcv+eNFaIEeT2exCZdi4LLCz15nlzOKHsWn3mWU7kcMd6Jtl3ICg+Cj3\nua5vAluDeqycX4FjhTIyZ2P4ktYZfTXRCQcTfqkC9S92m1i1qdeS+AEDgMBMgAh2\nhKivxz9hk1ED61sMgLQ0jM2fzxjm2jkOlElJtrXfpzgdceuMSaJG71W7XyOubK3s\nWf8mRf5TCvaljMC7gb9GnxsIaAPspyUfdJaXbap9pNeb/clacTv7kNriy6sG0vXf\nUxKPksyMsde59fbxYmXlN9NsTc2DTD6BIKtz87m5Zyjclhu5TFzpkTleZ9pf5lvc\nLLymHKgpcp6qIXE=\n-----END CERTIFICATE-----"
val local-good-pem = "-----BEGIN CERTIFICATE-----\nMIICgTCCAWmgAwIBAgIUUotxmzg/Zom9grnKO0xzgElTPa8wDQYJKoZIhvcNAQEL\nBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIx\nMjYxMDE2MTk0OTU2WjAVMRMwEQYDVQQDDApsb2NhbC1nb29kMFkwEwYHKoZIzj0C\nAQYIKoZIzj0DAQcDQgAEevDesrRG52d9qjDvEoTGDH2p6k5H2B/H2dyas01+HzZ8\nE4ldRT/MEgBZkUuYwG0seQ4u112YVP32npt4codFkaOBjzCBjDAzBggrBgEFBQcB\nAQQnMCUwIwYIKwYBBQUHMAGGF2h0dHA6Ly8xMjcuMC4wLjE6NDczMjEvMBUGA1Ud\nEQQOMAyCCmxvY2FsLWdvb2QwHQYDVR0OBBYEFLhoa+u1zVkhYB2gz/8w5pN0kzpw\nMB8GA1UdIwQYMBaAFAL5cKr2JNX5Yto3oExD4H8rJ1iKMA0GCSqGSIb3DQEBCwUA\nA4IBAQAbO02bMhPLJgLApjy/fNI1DudW5tvJgFf3xvhHWi5imIoUTardZ3uTaJiW\nDO8BIZ9QbcMou61oydXhthwFnQtXWeHQp6wj1Z/wPhu21tp5LQw5qptu064/TK5j\nSn2p0hNhywS7mCOqS80n98bjNUpb1jup9ei0pthLxnoBI2bIKLiBdYunUrfFpf8A\n6UsX+qqqVks6hQzpIplkL0Z2Ev8xXPPXs5l/U4iZZu8zFSBtsLhdPo2KdjSLvVsJ\n1FQ4j2Vj82gm5TDZ4oll73oH4rlJq9FL6paXuqgveCPOVVDVoe4ptRa8jBh3F1E2\nfIYhviwJPxTNLmPd0xXGWkCLH9Sr\n-----END CERTIFICATE-----"
val local-revoked-pem = "-----BEGIN CERTIFICATE-----\nMIIChzCCAW+gAwIBAgIUUotxmzg/Zom9grnKO0xzgElTPbAwDQYJKoZIhvcNAQEL\nBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIx\nMjYxMDE2MTk0OTU2WjAYMRYwFAYDVQQDDA1sb2NhbC1yZXZva2VkMFkwEwYHKoZI\nzj0CAQYIKoZIzj0DAQcDQgAE31TLis02sMI3rbYFsJlbBgqhG54U86+Zc4VjdQ2v\nMNPEUkTVXS7UPBxsPLqD2yEu2bpvprOdDSjlwk9KC/3UmKOBkjCBjzAzBggrBgEF\nBQcBAQQnMCUwIwYIKwYBBQUHMAGGF2h0dHA6Ly8xMjcuMC4wLjE6NDczMjEvMBgG\nA1UdEQQRMA+CDWxvY2FsLXJldm9rZWQwHQYDVR0OBBYEFJo6TGLSGm259Ij3IQ2i\nw2Y7SNIxMB8GA1UdIwQYMBaAFAL5cKr2JNX5Yto3oExD4H8rJ1iKMA0GCSqGSIb3\nDQEBCwUAA4IBAQCyevMFthZiWRAZyZWIkTc5RnMHCSNi4uSPBB0J3CSzimOFKvtH\nk0fqzDtizG4voG0yGFktxFJtl4DASCPwOTQ+v8SnQ+df15azrIhLWAKp1/t8xbIA\namVnuc/x54PWgyUupdHPLw1mTr7znHzwa3H6hbc8+x+EABS/NnU2p4jUsHJLS7oy\naSIZ0YWSEXphPmeM1kCkUbSGUAeUfgSPgdqjJiHsFy1vxNcWvXjIxTBAzUBjVQSk\nwnQV+uS1pqM4G/m5apNRafkKG5ZT0CsFu76/8a4DmxbIZfajyxF1ecJBSRuWswqc\nwebp7ywE7O96rXIRdfysqYinJNEMvRgGmllH\n-----END CERTIFICATE-----"
val local-good-key = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQglt7v5uAesZoYY/1c\nO5YRFlXBzEVMfGPJCq0k6l+MXPWhRANCAAR68N6ytEbnZ32qMO8ShMYMfanqTkfY\nH8fZ3JqzTX4fNnwTiV1FP8wSAFmRS5jAbSx5Di7XXZhU/faem3hyh0WR\n-----END PRIVATE KEY-----"
val local-revoked-key = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg9lozqXW8dJJAGJai\nxGucD7FDksp6SxabzZzKuWYFUyOhRANCAATfVMuKzTawwjettgWwmVsGCqEbnhTz\nr5lzhWN1Da8w08RSRNVdLtQ8HGw8uoPbIS7Zum+ms50NKOXCT0oL/dSY\n-----END PRIVATE KEY-----"
val req-good = "MFUwUzBRME8wTTAJBgUrDgMCGgUABBS/NFV1emn1jys3bK9TlfZwaiEExwQUAvlwqvYk1fli2jegTEPgfysnWIoCFFKLcZs4P2aJvYK5yjtMc4BJUz2r"
val req-revoked = "MFUwUzBRME8wTTAJBgUrDgMCGgUABBS/NFV1emn1jys3bK9TlfZwaiEExwQUAvlwqvYk1fli2jegTEPgfysnWIoCFFKLcZs4P2aJvYK5yjtMc4BJUz2s"
val req-other = "MFUwUzBRME8wTTAJBgUrDgMCGgUABBS/NFV1emn1jys3bK9TlfZwaiEExwQUAvlwqvYk1fli2jegTEPgfysnWIoCFFKLcZs4P2aJvYK5yjtMc4BJUz2t"
val req-local-good = "MFUwUzBRME8wTTAJBgUrDgMCGgUABBS/NFV1emn1jys3bK9TlfZwaiEExwQUAvlwqvYk1fli2jegTEPgfysnWIoCFFKLcZs4P2aJvYK5yjtMc4BJUz2v"
val req-local-revoked = "MFUwUzBRME8wTTAJBgUrDgMCGgUABBS/NFV1emn1jys3bK9TlfZwaiEExwQUAvlwqvYk1fli2jegTEPgfysnWIoCFFKLcZs4P2aJvYK5yjtMc4BJUz2w"
val resp-good-ca = "MIIFBwoBAKCCBQAwggT8BgkrBgEFBQcwAQEEggTtMIIE6TCBpaEZMBcxFTATBgNVBAMMDFRlc3QgT0NTUCBDQRgPMjAyNjExMDkxOTQ5NTZaMHcwdTBNMAkGBSsOAwIaBQAEFL80VXV6afWPKzdsr1OV9nBqIQTHBBQC+XCq9iTV+WLaN6BMQ+B/KydYigIUUotxmzg/Zom9grnKO0xzgElTPauAABgPMjAyNjExMDkxOTQ5NTZaoBEYDzIxMjYxMDE2MTk0OTU2WjANBgkqhkiG9w0BAQsFAAOCAQEAnUUdjDbWNj+lvLdJpPaMxpY8GIZrg9/wqIl9SqTIbuInTRSQQ6yYXBPovPCGOryXSlSBvRzylkJ7+ygrOT9PDsj81oMqLuiEimfl6+bYFoRoxAB1mghAjAkjE2KAkctsjrXJ6WsCcL1OQRi9FfXoghMJg9/qu+YHefgQjce99c5wXYy5WPyBeWPbA01R94Lyg7AZQExt6J6FMZGtupYpOGyX0+dkmsq/Ky0Pwq5a8gEyJXdLCxYhMNqHakLSZHHvastIJlyW41U6lJ5CtdkVBU3T4uiLF9ynN3wpLQuQRi/sx4wHHH2mwKc6ah7222ckqbUl7N+Q+BO7YZhBrEWrXqCCAykwggMlMIIDITCCAgmgAwIBAgIUR5SRFSyFscLhhCZDPMWaGJ4zbSkwDQYJKoZIhvcNAQELBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIxMjYxMDE2MTk0OTU2WjAXMRUwEwYDVQQDDAxUZXN0IE9DU1AgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC/AEEKpd+VsMDaEDEHbaPCz/91mDzO7Ckbu2ZFB22OTOkWhmcbFf3Q8q5AU/abd7kmsnAFyzhWgnb/LMWZBL48spbaKvdXTy3xty/SWh4RvybWK803AI0CN5qq19miYZ8oP+R86GZgOzsl703JcnfLMo5o7r8aLykuN7/ac0zOhQogt6SbzIBeoBvfJSkBH9AQqydO2wIkWVfLQYlP0dwUMuNmLRENgZkMDsyGmtytJsAGWFjVvIhxtnZPLvrmOAStr4poWsUgkBp8n/KwDgs67i7TtrNr1r9ckcSIbMamE7DPTKhlVPPapD1shGK5Qt55M97hakGJAAkdTd0JHdwvAgMBAAGjYzBhMB0GA1UdDgQWBBQC+XCq9iTV+WLaN6BMQ+B/KydYijAfBgNVHSMEGDAWgBQC+XCq9iTV+WLaN6BMQ+B/KydYijAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEAlCRZeGjlNf+EFvkbuMbP57ImrxQq3V4wAOinYNWy1CZRryqs0Nrgd1ft8b5EGmY0IrXxcsJEvAt9aGAWboLlQjcotjv9RF4MWixDnZyYuW2RXYUxvLDm5FI1sp4xEiWmec6MFuXc/Jkf/1EW7ttHqhmAxPzeV6072oS+GNzhiGJo7rBqzF8iPcOiSueILbpOrX22jr1TVlzOvOzpCNxXX5LlhBWG+YzZHAbSL03MIALUUIOZqth6tjRtcdD2HOIYfkVzwS85mprxtLRj+YQH+BkG2zxFGdPr2NyZlOGuIvwcnEZCSmv4ML65bfSMOVXFWcvsLXYwmIkKpf3mUPQ9tA=="
val resp-good-delegated = "MIIDbAoBAKCCA2UwggNhBgkrBgEFBQcwAQEEggNSMIIDTjCBoqEWMBQxEjAQBgNVBAMMCXJlc3BvbmRlchgPMjAyNjExMDkxOTQ5NTZaMHcwdTBNMAkGBSsOAwIaBQAEFL80VXV6afWPKzdsr1OV9nBqIQTHBBQC+XCq9iTV+WLaN6BMQ+B/KydYigIUUotxmzg/Zom9grnKO0xzgElTPauAABgPMjAyNjExMDkxOTQ5NTZaoBEYDzIxMjYxMDE2MTk0OTU2WjAKBggqhkjOPQQDAgNIADBFAiEA3lWWCndceVWuP+s/dGuQYMOnuVwFGQJFxFcrEls0PEgCIGmtnaep2z9ZZzH7Y/CIoMqkjEdP1YzUI0fbm5lflKNvoIICTzCCAkswggJHMIIBL6ADAgECAhRSi3GbOD9mib2Cuco7THOASVM9rjANBgkqhkiG9w0BAQsFADAXMRUwEwYDVQQDDAxUZXN0IE9DU1AgQ0EwIBcNMjYxMTA5MTk0OTU2WhgPMjEyNjEwMTYxOTQ5NTZaMBQxEjAQBgNVBAMMCXJlc3BvbmRlcjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABLTu9u6eTOtuJOz9mwkXBdt8c9W7mkCE1PFmI84s6VPK2P6sciNNYiYGfzkhVOc6XPU4WuOKlM3bnaOer7qxHLWjVzBVMBMGA1UdJQQMMAoGCCsGAQUFBwMJMB0GA1UdDgQWBBSnRngie36jEmUOcNa1xkuQJt6XgjAfBgNVHSMEGDAWgBQC+XCq9iTV+WLaN6BMQ+B/KydYijANBgkqhkiG9w0BAQsFAAOCAQEAbr6ZHeM/1LZjcK8Ry/540VogR5PZ7EJl2LgssLPXmeXM4oexafeZZTuRwx3om2XcgKD4KPe5rm8CW4N6rJxfgWOFMjJnY/iS1hl9NdEJBxN+qQL1L3abWLWp15L4AQOAwEyACHaEqK/HP2GTUQPrWwyAtDSMzZ/PGObaOQ6USUm2td+nOB1x64xJokbvVbtfI65srexZ/yZF/lMK9qWMwLuBv0afGwhoA+ynJR90lpdtqn2k15v9yVpxO/uQ2uLLqwbS9d9TEo+SzIyx17n19vFiZeU302xNzYNMPoEgq3PzublnKNyWG7lMXOmROV5n2l/mW9wsvKYcqClynqohcQ=="
val resp-revoked-ca = "MIIFHwoBAKCCBRgwggUUBgkrBgEFBQcwAQEEggUFMIIFATCBvaEZMBcxFTATBgNVBAMMDFRlc3QgT0NTUCBDQRgPMjAyNjExMDkxOTQ5NTZaMIGOMIGLME0wCQYFKw4DAhoFAAQUvzRVdXpp9Y8rN2yvU5X2cGohBMcEFAL5cKr2JNX5Yto3oExD4H8rJ1iKAhRSi3GbOD9mib2Cuco7THOASVM9rKEWGA8yMDI1MDEwMjAzMDQwNVqgAwoBARgPMjAyNjExMDkxOTQ5NTZaoBEYDzIxMjYxMDE2MTk0OTU2WjANBgkqhkiG9w0BAQsFAAOCAQEAdEk2VVszZ/xDvDgReBylS7ESXjEaEwHhoRgRKJs0savCDE6jB80APAYNLeLy5UxJWoszTNnk0nGUv9zUtWfHGAGt4hy4ZtIaAdAMzMqFAlA8LrJyORcqfL/2qXAXR9TesAMpj3EqMZJyeyFwy75kDuSE5g3U8Nw/CjJ7j/6RXR5KSd12EsFEhThkimSjGx3n9i54o/JXeckX0wdGdRfgzS13ES8QSjXvU+n/P5nXgeBSRAP8wwWFGkLUMeIwNK+VQ0Dt6rghcu0O7AB5SunYuMoQgrsC/t/pA624EvLZZHGopKt/dn307km/FgXmT8y9nVScTQBiLvuAaDr0PciUu6CCAykwggMlMIIDITCCAgmgAwIBAgIUR5SRFSyFscLhhCZDPMWaGJ4zbSkwDQYJKoZIhvcNAQELBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIxMjYxMDE2MTk0OTU2WjAXMRUwEwYDVQQDDAxUZXN0IE9DU1AgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC/AEEKpd+VsMDaEDEHbaPCz/91mDzO7Ckbu2ZFB22OTOkWhmcbFf3Q8q5AU/abd7kmsnAFyzhWgnb/LMWZBL48spbaKvdXTy3xty/SWh4RvybWK803AI0CN5qq19miYZ8oP+R86GZgOzsl703JcnfLMo5o7r8aLykuN7/ac0zOhQogt6SbzIBeoBvfJSkBH9AQqydO2wIkWVfLQYlP0dwUMuNmLRENgZkMDsyGmtytJsAGWFjVvIhxtnZPLvrmOAStr4poWsUgkBp8n/KwDgs67i7TtrNr1r9ckcSIbMamE7DPTKhlVPPapD1shGK5Qt55M97hakGJAAkdTd0JHdwvAgMBAAGjYzBhMB0GA1UdDgQWBBQC+XCq9iTV+WLaN6BMQ+B/KydYijAfBgNVHSMEGDAWgBQC+XCq9iTV+WLaN6BMQ+B/KydYijAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEAlCRZeGjlNf+EFvkbuMbP57ImrxQq3V4wAOinYNWy1CZRryqs0Nrgd1ft8b5EGmY0IrXxcsJEvAt9aGAWboLlQjcotjv9RF4MWixDnZyYuW2RXYUxvLDm5FI1sp4xEiWmec6MFuXc/Jkf/1EW7ttHqhmAxPzeV6072oS+GNzhiGJo7rBqzF8iPcOiSueILbpOrX22jr1TVlzOvOzpCNxXX5LlhBWG+YzZHAbSL03MIALUUIOZqth6tjRtcdD2HOIYfkVzwS85mprxtLRj+YQH+BkG2zxFGdPr2NyZlOGuIvwcnEZCSmv4ML65bfSMOVXFWcvsLXYwmIkKpf3mUPQ9tA=="
val resp-revoked-delegated = "MIIDhAoBAKCCA30wggN5BgkrBgEFBQcwAQEEggNqMIIDZjCBuqEWMBQxEjAQBgNVBAMMCXJlc3BvbmRlchgPMjAyNjExMDkxOTQ5NTZaMIGOMIGLME0wCQYFKw4DAhoFAAQUvzRVdXpp9Y8rN2yvU5X2cGohBMcEFAL5cKr2JNX5Yto3oExD4H8rJ1iKAhRSi3GbOD9mib2Cuco7THOASVM9rKEWGA8yMDI1MDEwMjAzMDQwNVqgAwoBARgPMjAyNjExMDkxOTQ5NTZaoBEYDzIxMjYxMDE2MTk0OTU2WjAKBggqhkjOPQQDAgNIADBFAiEAmI4gHhWv3nLi8VYorNdq2ehzw4vNoi+6deQaO9a3AC4CIASBCOHi5XOybnEr8WlWnBFsWYLHzxiUNRLbAslSVZvzoIICTzCCAkswggJHMIIBL6ADAgECAhRSi3GbOD9mib2Cuco7THOASVM9rjANBgkqhkiG9w0BAQsFADAXMRUwEwYDVQQDDAxUZXN0IE9DU1AgQ0EwIBcNMjYxMTA5MTk0OTU2WhgPMjEyNjEwMTYxOTQ5NTZaMBQxEjAQBgNVBAMMCXJlc3BvbmRlcjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABLTu9u6eTOtuJOz9mwkXBdt8c9W7mkCE1PFmI84s6VPK2P6sciNNYiYGfzkhVOc6XPU4WuOKlM3bnaOer7qxHLWjVzBVMBMGA1UdJQQMMAoGCCsGAQUFBwMJMB0GA1UdDgQWBBSnRngie36jEmUOcNa1xkuQJt6XgjAfBgNVHSMEGDAWgBQC+XCq9iTV+WLaN6BMQ+B/KydYijANBgkqhkiG9w0BAQsFAAOCAQEAbr6ZHeM/1LZjcK8Ry/540VogR5PZ7EJl2LgssLPXmeXM4oexafeZZTuRwx3om2XcgKD4KPe5rm8CW4N6rJxfgWOFMjJnY/iS1hl9NdEJBxN+qQL1L3abWLWp15L4AQOAwEyACHaEqK/HP2GTUQPrWwyAtDSMzZ/PGObaOQ6USUm2td+nOB1x64xJokbvVbtfI65srexZ/yZF/lMK9qWMwLuBv0afGwhoA+ynJR90lpdtqn2k15v9yVpxO/uQ2uLLqwbS9d9TEo+SzIyx17n19vFiZeU302xNzYNMPoEgq3PzublnKNyWG7lMXOmROV5n2l/mW9wsvKYcqClynqohcQ=="
val resp-other-ca = "MIIFBwoBAKCCBQAwggT8BgkrBgEFBQcwAQEEggTtMIIE6TCBpaEZMBcxFTATBgNVBAMMDFRlc3QgT0NTUCBDQRgPMjAyNjExMDkxOTQ5NTZaMHcwdTBNMAkGBSsOAwIaBQAEFL80VXV6afWPKzdsr1OV9nBqIQTHBBQC+XCq9iTV+WLaN6BMQ+B/KydYigIUUotxmzg/Zom9grnKO0xzgElTPa2CABgPMjAyNjExMDkxOTQ5NTZaoBEYDzIxMjYxMDE2MTk0OTU2WjANBgkqhkiG9w0BAQsFAAOCAQEAQFiB5lyflm0DTkTKHcmAgqiVKS1RNiB4dbWGSKOceYjVWR4ox1/ocTKtQNCOEEDsBA5Hvudw4rXHvyKcJ7iOE2FquI23FEpnIb2cB6Ni8KgWe0y67km/U94h308rzlo92dg5h3IZIdQ47o3A5cII4bYeGJAJhOEwNhwAgHWaHytEobEU+zsYQiZOUt7RPMfsuRPjJ2e04OVioxlp9nQBEYMpVgTY9XpaNXtNlu89MjUNXqlkKF6DgWAK/E0TjQscnG2mdro/XmnizJV+WeNVlNt6r5ltYmcAXDMZ+lFe/sF6CWXm1ww/n6q1RCfJXF/HdVVtysgQlDy+f4T3H8POZqCCAykwggMlMIIDITCCAgmgAwIBAgIUR5SRFSyFscLhhCZDPMWaGJ4zbSkwDQYJKoZIhvcNAQELBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIxMjYxMDE2MTk0OTU2WjAXMRUwEwYDVQQDDAxUZXN0IE9DU1AgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC/AEEKpd+VsMDaEDEHbaPCz/91mDzO7Ckbu2ZFB22OTOkWhmcbFf3Q8q5AU/abd7kmsnAFyzhWgnb/LMWZBL48spbaKvdXTy3xty/SWh4RvybWK803AI0CN5qq19miYZ8oP+R86GZgOzsl703JcnfLMo5o7r8aLykuN7/ac0zOhQogt6SbzIBeoBvfJSkBH9AQqydO2wIkWVfLQYlP0dwUMuNmLRENgZkMDsyGmtytJsAGWFjVvIhxtnZPLvrmOAStr4poWsUgkBp8n/KwDgs67i7TtrNr1r9ckcSIbMamE7DPTKhlVPPapD1shGK5Qt55M97hakGJAAkdTd0JHdwvAgMBAAGjYzBhMB0GA1UdDgQWBBQC+XCq9iTV+WLaN6BMQ+B/KydYijAfBgNVHSMEGDAWgBQC+XCq9iTV+WLaN6BMQ+B/KydYijAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEAlCRZeGjlNf+EFvkbuMbP57ImrxQq3V4wAOinYNWy1CZRryqs0Nrgd1ft8b5EGmY0IrXxcsJEvAt9aGAWboLlQjcotjv9RF4MWixDnZyYuW2RXYUxvLDm5FI1sp4xEiWmec6MFuXc/Jkf/1EW7ttHqhmAxPzeV6072oS+GNzhiGJo7rBqzF8iPcOiSueILbpOrX22jr1TVlzOvOzpCNxXX5LlhBWG+YzZHAbSL03MIALUUIOZqth6tjRtcdD2HOIYfkVzwS85mprxtLRj+YQH+BkG2zxFGdPr2NyZlOGuIvwcnEZCSmv4ML65bfSMOVXFWcvsLXYwmIkKpf3mUPQ9tA=="
val resp-other-delegated = "MIIDawoBAKCCA2QwggNgBgkrBgEFBQcwAQEEggNRMIIDTTCBoqEWMBQxEjAQBgNVBAMMCXJlc3BvbmRlchgPMjAyNjExMDkxOTQ5NTZaMHcwdTBNMAkGBSsOAwIaBQAEFL80VXV6afWPKzdsr1OV9nBqIQTHBBQC+XCq9iTV+WLaN6BMQ+B/KydYigIUUotxmzg/Zom9grnKO0xzgElTPa2CABgPMjAyNjExMDkxOTQ5NTZaoBEYDzIxMjYxMDE2MTk0OTU2WjAKBggqhkjOPQQDAgNHADBEAiBU/KIIBtt5UwYZkHZvpfpR6roFcpuKhUZoemJPBHWWAAIgeiqZ6D8fsoRl4HDg3M5KvU5ZpfGizwrHS3DifYi/UxigggJPMIICSzCCAkcwggEvoAMCAQICFFKLcZs4P2aJvYK5yjtMc4BJUz2uMA0GCSqGSIb3DQEBCwUAMBcxFTATBgNVBAMMDFRlc3QgT0NTUCBDQTAgFw0yNjExMDkxOTQ5NTZaGA8yMTI2MTAxNjE5NDk1NlowFDESMBAGA1UEAwwJcmVzcG9uZGVyMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEtO727p5M624k7P2bCRcF23xz1buaQITU8WYjzizpU8rY/qxyI01iJgZ/OSFU5zpc9Tha44qUzdudo56vurEctaNXMFUwEwYDVR0lBAwwCgYIKwYBBQUHAwkwHQYDVR0OBBYEFKdGeCJ7fqMSZQ5w1rXGS5Am3peCMB8GA1UdIwQYMBaAFAL5cKr2JNX5Yto3oExD4H8rJ1iKMA0GCSqGSIb3DQEBCwUAA4IBAQBuvpkd4z/UtmNwrxHL/njRWiBHk9nsQmXYuCyws9eZ5czih7Fp95llO5HDHeibZdyAoPgo97mubwJbg3qsnF+BY4UyMmdj+JLWGX010QkHE36pAvUvdptYtanXkvgBA4DATIAIdoSor8c/YZNRA+tbDIC0NIzNn88Y5to5DpRJSba136c4HXHrjEmiRu9Vu18jrmyt7Fn/JkX+Uwr2pYzAu4G/Rp8bCGgD7KclH3SWl22qfaTXm/3JWnE7+5Da4surBtL131MSj5LMjLHXufX28WJl5TfTbE3Ng0w+gSCrc/O5uWco3JYbuUxc6ZE5XmfaX+Zb3Cy8phyoKXKeqiFx"
val resp-good-unauthorized = "MIIDfQoBAKCCA3YwggNyBgkrBgEFBQcwAQEEggNjMIIDXzCBnqESMBAxDjAMBgNVBAMMBW90aGVyGA8yMDI2MTEwOTE5NDk1NlowdzB1ME0wCQYFKw4DAhoFAAQUvzRVdXpp9Y8rN2yvU5X2cGohBMcEFAL5cKr2JNX5Yto3oExD4H8rJ1iKAhRSi3GbOD9mib2Cuco7THOASVM9q4AAGA8yMDI2MTEwOTE5NDk1NlqgERgPMjEyNjEwMTYxOTQ5NTZaMAoGCCqGSM49BAMCA0cAMEQCICR51lBzq/1VbBQ70Cnuvv2IevShRZDm5c3rAk3xs1+cAiBIKDVhLfxDfSSDZQ/8Thsin8XPqvGNH9fOcxT2mqLZQKCCAmUwggJhMIICXTCCAUWgAwIBAgIUUotxmzg/Zom9grnKO0xzgElTPa0wDQYJKoZIhvcNAQELBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIxMjYxMDE2MTk0OTU2WjAQMQ4wDAYDVQQDDAVvdGhlcjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABKYrazZ6cGKqHNMKFFk8698z0kZg56Sw1VnoM1vja58yo8HxYgPMCWbTsYw6GX7FzND5ZzO35B90HoY4j9TrWhujcTBvMC0GCCsGAQUFBwEBBCEwHzAdBggrBgEFBQcwAYYRaHR0cDovL29jc3AudGVzdC8wHQYDVR0OBBYEFKS9BKycSRBQ9rF67VsN5IKtvTYAMB8GA1UdIwQYMBaAFAL5cKr2JNX5Yto3oExD4H8rJ1iKMA0GCSqGSIb3DQEBCwUAA4IBAQBQnDYHGSqwUIP3huzoqZH2rKVZMKVUQfmWts7S47167IDxnqMlBRFn4bJPAAraV6GxRooA4h0FF1Kv3YEa0wWk3auWSihF3OuCepGuJFfjWX9d21IjAk5XSv1TyhOjpm1zGvBsrsG0hKqx+rdKrQCfY4P58d938/YBvv8rpiRnM92D3u5OXmO7UDKl3K7JQ/93os84gf2lpLWOBvzr/R4y8G2uml704j1YN/SdEDR6rg91cFwanJ9XfQ7dPHpBPuO86XKXRBLtHvavAx5NfhJuUzJ4B1KRqnlOMFyQFBWC61k9Y0CaFuRkfJvWqd7dIxg+EYI2GjHZeqXq9FkBnIMM"
val resp-local-good-ca = "MIIFBwoBAKCCBQAwggT8BgkrBgEFBQcwAQEEggTtMIIE6TCBpaEZMBcxFTATBgNVBAMMDFRlc3QgT0NTUCBDQRgPMjAyNjExMDkxOTQ5NTZaMHcwdTBNMAkGBSsOAwIaBQAEFL80VXV6afWPKzdsr1OV9nBqIQTHBBQC+XCq9iTV+WLaN6BMQ+B/KydYigIUUotxmzg/Zom9grnKO0xzgElTPa+AABgPMjAyNjExMDkxOTQ5NTZaoBEYDzIxMjYxMDE2MTk0OTU2WjANBgkqhkiG9w0BAQsFAAOCAQEASMifIXq8KVKQlTj8T0zA1MfYVJfRp/DQqtQf39q0dyeXPZ1DF40UzpD/UgFhIwIhCnl7Y6w5ToqQ9h6AEkiUGEYBBC+GV42oRy5qi2nt2roX+1vea1Ipxnk9spaQcQHQ77Whz42yviZKG/oFIzC7V2DAUstC+6uhjON0ygsoYQj3cmEm95JcObLAuOw9gA8eLaWhCLaKPP9zwcDTl8MKEutnfTWy/jz/8Xh3RHoiGM0JSjPH0GgkXKIw7DJSVBsVP/s70CxoFuBL/lUjMq1X+oIQZDPdAk0WvOo8hmXCrHvCeD4uMpXZ33myqBe8r1lD7txy6AM6rWQcF6W5vYfi4aCCAykwggMlMIIDITCCAgmgAwIBAgIUR5SRFSyFscLhhCZDPMWaGJ4zbSkwDQYJKoZIhvcNAQELBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIxMjYxMDE2MTk0OTU2WjAXMRUwEwYDVQQDDAxUZXN0IE9DU1AgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC/AEEKpd+VsMDaEDEHbaPCz/91mDzO7Ckbu2ZFB22OTOkWhmcbFf3Q8q5AU/abd7kmsnAFyzhWgnb/LMWZBL48spbaKvdXTy3xty/SWh4RvybWK803AI0CN5qq19miYZ8oP+R86GZgOzsl703JcnfLMo5o7r8aLykuN7/ac0zOhQogt6SbzIBeoBvfJSkBH9AQqydO2wIkWVfLQYlP0dwUMuNmLRENgZkMDsyGmtytJsAGWFjVvIhxtnZPLvrmOAStr4poWsUgkBp8n/KwDgs67i7TtrNr1r9ckcSIbMamE7DPTKhlVPPapD1shGK5Qt55M97hakGJAAkdTd0JHdwvAgMBAAGjYzBhMB0GA1UdDgQWBBQC+XCq9iTV+WLaN6BMQ+B/KydYijAfBgNVHSMEGDAWgBQC+XCq9iTV+WLaN6BMQ+B/KydYijAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEAlCRZeGjlNf+EFvkbuMbP57ImrxQq3V4wAOinYNWy1CZRryqs0Nrgd1ft8b5EGmY0IrXxcsJEvAt9aGAWboLlQjcotjv9RF4MWixDnZyYuW2RXYUxvLDm5FI1sp4xEiWmec6MFuXc/Jkf/1EW7ttHqhmAxPzeV6072oS+GNzhiGJo7rBqzF8iPcOiSueILbpOrX22jr1TVlzOvOzpCNxXX5LlhBWG+YzZHAbSL03MIALUUIOZqth6tjRtcdD2HOIYfkVzwS85mprxtLRj+YQH+BkG2zxFGdPr2NyZlOGuIvwcnEZCSmv4ML65bfSMOVXFWcvsLXYwmIkKpf3mUPQ9tA=="
val resp-local-revoked-ca = "MIIFHwoBAKCCBRgwggUUBgkrBgEFBQcwAQEEggUFMIIFATCBvaEZMBcxFTATBgNVBAMMDFRlc3QgT0NTUCBDQRgPMjAyNjExMDkxOTQ5NTZaMIGOMIGLME0wCQYFKw4DAhoFAAQUvzRVdXpp9Y8rN2yvU5X2cGohBMcEFAL5cKr2JNX5Yto3oExD4H8rJ1iKAhRSi3GbOD9mib2Cuco7THOASVM9sKEWGA8yMDI1MDEwMjAzMDQwNVqgAwoBARgPMjAyNjExMDkxOTQ5NTZaoBEYDzIxMjYxMDE2MTk0OTU2WjANBgkqhkiG9w0BAQsFAAOCAQEAfitrY7C30U6ofQ5HlbqAqIETqyIqme1kh9mQOedNYkj150BM4kh+ZrZ8VvTukEGP+e4QDW/MMDbjseY2vD0oxxm7au9DdjBBe3K8VYyRLt7WHfSxwor/5hdwpUwX0wFL1XcXE5Qeov0El1+LBKOkIyftGVUy26KjwU6w1pJh8ayFFR6EjJqi+puoYyO3HkAUF35wIqtotWC+aC2c/MArJR2kvn0f+8akkPDMpfPJ721YgTDxidIaYenspozHHvFP0Trr2wDGsM2LfZn13gyI38kGazuEFFwXbKRK9Hv8PqVVvDOde30L9WCVfNjSc2yiXkF2J3jfa1XlFtREV1pJRKCCAykwggMlMIIDITCCAgmgAwIBAgIUR5SRFSyFscLhhCZDPMWaGJ4zbSkwDQYJKoZIhvcNAQELBQAwFzEVMBMGA1UEAwwMVGVzdCBPQ1NQIENBMCAXDTI2MTEwOTE5NDk1NloYDzIxMjYxMDE2MTk0OTU2WjAXMRUwEwYDVQQDDAxUZXN0IE9DU1AgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC/AEEKpd+VsMDaEDEHbaPCz/91mDzO7Ckbu2ZFB22OTOkWhmcbFf3Q8q5AU/abd7kmsnAFyzhWgnb/LMWZBL48spbaKvdXTy3xty/SWh4RvybWK803AI0CN5qq19miYZ8oP+R86GZgOzsl703JcnfLMo5o7r8aLykuN7/ac0zOhQogt6SbzIBeoBvfJSkBH9AQqydO2wIkWVfLQYlP0dwUMuNmLRENgZkMDsyGmtytJsAGWFjVvIhxtnZPLvrmOAStr4poWsUgkBp8n/KwDgs67i7TtrNr1r9ckcSIbMamE7DPTKhlVPPapD1shGK5Qt55M97hakGJAAkdTd0JHdwvAgMBAAGjYzBhMB0GA1UdDgQWBBQC+XCq9iTV+WLaN6BMQ+B/KydYijAfBgNVHSMEGDAWgBQC+XCq9iTV+WLaN6BMQ+B/KydYijAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEAlCRZeGjlNf+EFvkbuMbP57ImrxQq3V4wAOinYNWy1CZRryqs0Nrgd1ft8b5EGmY0IrXxcsJEvAt9aGAWboLlQjcotjv9RF4MWixDnZyYuW2RXYUxvLDm5FI1sp4xEiWmec6MFuXc/Jkf/1EW7ttHqhmAxPzeV6072oS+GNzhiGJo7rBqzF8iPcOiSueILbpOrX22jr1TVlzOvOzpCNxXX5LlhBWG+YzZHAbSL03MIALUUIOZqth6tjRtcdD2HOIYfkVzwS85mprxtLRj+YQH+BkG2zxFGdPr2NyZlOGuIvwcnEZCSmv4ML65bfSMOVXFWcvsLXYwmIkKpf3mUPQ9tA=="

/* Made with openssl 3.5 with this script:
set -e
O=openssl
# CA (RSA)
$O req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 36500 -subj "/CN=Test OCSP CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
mkcert() {  # name, extra extensions
  $O req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout $1.key -out $1.csr -subj "/CN=$1" 2>/dev/null
  printf "$2" > $1.cnf
  $O x509 -req -in $1.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out $1.pem -days 36500 -extfile $1.cnf 2>/dev/null
}
mkcert good "authorityInfoAccess=OCSP;URI:http://ocsp.test/\nsubjectAltName=DNS:good\n"
mkcert revoked "authorityInfoAccess=OCSP;URI:http://ocsp.test/\nsubjectAltName=DNS:revoked\n"
mkcert other "authorityInfoAccess=OCSP;URI:http://ocsp.test/\n"
mkcert responder "extendedKeyUsage=OCSPSigning\n"
# with a responder on a fixed local port, for tls-connect(ocsp = True)
mkcert local-good "authorityInfoAccess=OCSP;URI:http://127.0.0.1:47321/\nsubjectAltName=DNS:local-good\n"
mkcert local-revoked "authorityInfoAccess=OCSP;URI:http://127.0.0.1:47321/\nsubjectAltName=DNS:local-revoked\n"
# the CA database: good valid, revoked revoked (keyCompromise); `other` is not in it
: > index.txt
for n in good revoked local-good local-revoked; do
  ser=$($O x509 -in $n.pem -noout -serial | cut -d= -f2)
  subj=$($O x509 -in $n.pem -noout -subject -nameopt compat | sed 's/^subject=//')
  if [ $n = revoked ] || [ $n = local-revoked ]; then
    printf "R\t21000101000000Z\t250102030405Z,keyCompromise\t%s\tunknown\t%s\n" "$ser" "$subj" >> index.txt
  else
    printf "V\t21000101000000Z\t\t%s\tunknown\t%s\n" "$ser" "$subj" >> index.txt
  fi
done
for n in good revoked other local-good local-revoked; do
  $O ocsp -issuer ca.pem -cert $n.pem -no_nonce -reqout req-$n.der 2>/dev/null
  # signed by the CA itself, and by the delegated responder
  $O ocsp -index index.txt -CA ca.pem -rsigner ca.pem -rkey ca.key -reqin req-$n.der -respout resp-$n-ca.der -ndays 36500 2>/dev/null
  $O ocsp -index index.txt -CA ca.pem -rsigner responder.pem -rkey responder.key -reqin req-$n.der -respout resp-$n-delegated.der -ndays 36500 2>/dev/null
done
# a delegated responder that is not authorized (no OCSPSigning usage): `other` signs
$O ocsp -index index.txt -CA ca.pem -rsigner other.pem -rkey other.key -reqin req-good.der -respout resp-good-unauthorized.der -ndays 36500 2>/dev/null
# check with openssl
$O ocsp -issuer ca.pem -cert good.pem -respin resp-good-ca.der -CAfile ca.pem 2>&1 | head -2
$O ocsp -issuer ca.pem -cert revoked.pem -respin resp-revoked-delegated.der -CAfile ca.pem 2>&1 | head -4
*/
