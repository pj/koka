// Requires internet access; not part of the default test run.
import std/async
import std/async/os/net
import std/async/os/tls
import std/async/os/http

fun main()
  val res = http-get("https://example.com/")
  println((res.status, res.body-text.contains("Example Domain")))
  val res2 = http-get("https://www.google.com/")
  println(res2.status < 500)
  // raw TLS stream
  val text = tls-connect("example.com", 443) fn(s : net-stream)
    s.write-text("HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
    s.read-all-text
  println(text.starts-with("HTTP/1.1 200").is-just)
  // certificate errors are reported
  println(catch(fn(e) "rejected: " ++ (if e.message.contains("certificate") || e.message.contains("CERT") || e.message.contains("verif") then "certificate" else e.message),
                { http-get("https://expired.badssl.com/").status.show }))
  println(catch(fn(e) "rejected: " ++ (if e.message.contains("certificate") || e.message.contains("CERT") || e.message.contains("verif") || e.message.contains("altname") || e.message.contains("name") then "certificate" else e.message),
                { http-get("https://wrong.host.badssl.com/").status.show }))
  // ... unless verification is disabled
  val insecure = tls-connect("expired.badssl.com", 443, verify=False) fn(s : net-stream)
    s.write-text("HEAD / HTTP/1.1\r\nHost: expired.badssl.com\r\nConnection: close\r\n\r\n")
    s.read-all-text
  println(insecure.starts-with("HTTP/1.1").is-just)
