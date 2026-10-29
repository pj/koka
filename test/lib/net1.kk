import std/net/url
import std/data/csv
import std/data/uuid
import std/crypto/hash
import std/text/encoding
import std/num/random

fun main()
  // urls
  val u = parse-url("HTTPS://user:pw@Example.com:8080/a/b/c?x=1&y=two%20words&z=a+b#frag").unjust
  println((u.scheme, u.userinfo, u.host, u.port))
  println((u.path, u.query, u.fragment))
  println(u.query-params)
  println((u.query-param("y"), u.effective-port, parse-url("http://h/").unjust.effective-port))
  println(u.show)
  println(parse-url("http://[::1]:3000/x").map(fn(v) (v.host, v.port, v.show)))
  println(parse-url("mailto:someone@example.com").map(fn(v) (v.scheme, v.path)))
  println(parse-url("/just/a/path?q").map(fn(v) (v.scheme, v.path, v.query)))
  println(parse-url("http://h:notaport/").is-nothing)
  println(u.with-query-params([("k","v w"),("é","&")]).show)
  // RFC 3986 section 5.4.1 examples
  val base = parse-url("http://a/b/c/d;p?q").unjust
  ["g:h", "g", "./g", "g/", "/g", "//g", "?y", "g?y", "#s", "g#s", "g?y#s", ";x", "g;x", "", ".", "./", "..", "../", "../g", "../..", "../../", "../../g", "../../../g", "/./g", "/../g", "g.", ".g", "g..", "..g", "./../g", "./g/.", "g/./h", "g/../h"].foreach fn(r)
    println(r ++ " -> " ++ base.resolve(r).show)
  // csv
  val rows = parse-csv("name,age,note\nann,30,\"likes, commas\"\r\n\"bob \"\"the builder\"\"\",25,\"multi\nline\"\n,,\n")
  println(rows)
  println(rows.to-csv.show)
  println(parse-csv(rows.to-csv) == rows)
  println(parse-csv-records("a;b\n1;2\n3;4", sep=';'))
  println(catch(fn(e) e.message, { parse-csv("\"oops").show }))
  // uuid
  val id = pseudo-random(1, random-uuid-v4)
  println((id.show, id.version, parse-uuid(id.show) == Just(id), id.bytes.length))
  println(parse-uuid("{550E8400-E29B-41D4-A716-446655440000}").map(show))
  println((parse-uuid("not-a-uuid").is-nothing, nil-uuid.show))
  val v4 = new-uuid-v4()
  val v7a = new-uuid-v7()
  val v7b = new-uuid-v7()
  println((v4.version, v7a.version, v4.show.count, v4 != v7a, v7a.hi / 65536 <= v7b.hi / 65536))
  // sha (FIPS 180 test vectors)
  println("".bytes.sha256.hex-encode)
  println("abc".bytes.sha256.hex-encode)
  println("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".bytes.sha256.hex-encode)
  println("abc".bytes.sha1.hex-encode)
  println("The quick brown fox jumps over the lazy dog".bytes.sha1.hex-encode)
  println("a".repeat(1000).bytes.sha256.hex-encode)
  // RFC 4231 test case 2
  println(hmac-sha256("Jefe".bytes, "what do ya want for nothing?".bytes).hex-encode)
  println(hmac-sha256(list(1,131).map(fn(_) 0xaa).vector.bytes, "Test Using Larger Than Block-Size Key - Hash Key First".bytes).hex-encode)
  println((constant-time-equals("ab".bytes, "ab".bytes), constant-time-equals("ab".bytes, "ac".bytes)))
