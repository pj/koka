import std/text/encoding
import std/text/builder

fun roundtrip( s : string ) : bool
  s.bytes.base64-encode.base64-decode.map(string) == Just(s)

fun main()
  // RFC 4648 test vectors
  println(["", "f", "fo", "foo", "foob", "fooba", "foobar"].map(fn(s) s.bytes.base64-encode))
  println(["", "Zg", "Zm8", "Zm9v", "Zm9vYg", "Zm9vYmE", "Zm9vYmFy"].map(fn(s) s.base64-decode.map(string)))
  println(["Zg==", "Zm8=", "Zm9v YmFy\n"].map(fn(s) s.base64-decode.map(string)))
  println(("a".base64-decode.is-nothing, "Zm9v!".base64-decode.is-nothing))
  println([255,254,253].vector.bytes.base64-encode ++ " " ++ [255,254,253].vector.bytes.base64-encode(url-safe=True) ++ " " ++ [255].vector.bytes.base64-encode(pad=False))
  println(["héllo wörld 😀", "line1\nline2", "the quick brown fox jumps over the lazy dog"].all(roundtrip))
  println(list(0,255).vector.bytes.base64-encode.base64-decode.map(fn(b) b.list) == Just(list(0,255)))
  // hex
  println(("Hello".bytes.hex-encode, [0,15,16,255].vector.bytes.hex-encode(upper=True)))
  println(("48656c6c6f".hex-decode.map(string), "48 65 6C".hex-decode.map(string), "abc".hex-decode.is-nothing, "zz".hex-decode.is-nothing))
  // percent
  println(("a b&c=d/é~".percent-encode, "/path with/space".percent-encode(safe="/")))
  println(("a%20b%26c".percent-decode, "a+b".percent-decode(plus-as-space=True), "%E2%82%AC".percent-decode, "%zz".percent-decode))
  // builder
  println(builder().add("hello").add-char(',').add(" world").add-all(["!","?"], sep=" ").string)
  val s = build
    emit("<ul>")
    for(1,3) fn(i) emit("<li>" ++ i.show ++ "</li>")
    emit-line("</ul>")
  print(s)
  println(build({ for(1,10000) fn(i) emit("x") }).count)
