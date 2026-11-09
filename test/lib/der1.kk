// std/data/der: ASN.1 DER encoding and decoding
import std/data/der
import std/text/encoding

fun hex( b : bytes ) : string
  hex-encode(b)

fun roundtrip( d : der ) : <div,exn> string
  val b = d.encode
  b.hex ++ (if b.decode == d then "" else " (differs)")

fun main()
  // integers: two's complement in as few bytes as possible
  [0, 1, 127, 128, 255, 256, -1, -128, -129, -256, 65535, 123456789012345678901234567890].foreach fn(i)
    println((i, roundtrip(Der-int(i))))
  // other primitives
  println(roundtrip(Der-bool(True)))
  println(roundtrip(Der-null))
  println(roundtrip(Der-oid("1.2.840.113549.1.1.11")))
  println(roundtrip(Der-oid("2.999.3")))
  println(roundtrip(Der-octets("hi".bytes)))
  println(roundtrip(Der-bits("ab".bytes, 4)))
  println(roundtrip(Der-string(12, "héllo")))
  println(roundtrip(Der-time(24, "20250102030405Z")))
  // long lengths and large tag numbers
  val long = Der-octets("x".repeat(300).bytes)
  println(long.encode.subbytes(0, 4).hex ++ " " ++ (long.encode.decode == long).show)
  println(roundtrip(Der-tagged(2, 40, False, "z".bytes)))
  // SET OF is sorted, SEQUENCE is not
  println(Der-set([Der-int(3), Der-int(1), Der-int(2)]).encode.hex)
  println(Der-seq([Der-int(3), Der-int(1)]).encode.hex)
  // explicit and implicit tags
  val ex = tag-explicit(0, Der-int(5))
  println((ex.encode.hex, ex.explicit.show))
  val im = tag-implicit(1, Der-octets("ab".bytes))
  println((im.encode.hex, im.implicit(4).show))
  // structure as received
  val s = Der-seq([Der-int(1), Der-seq([Der-null]), Der-bool(False)]).encode
  println(s.elements.map(hex))
  println((s ++ Der-null.encode).split.map(hex))
  println(s.decode.show)
  // errors
  println(try({ "3005".hex-decode.default(bytes/empty).decode }).is-error)          // too short
  println(try({ "0500ff".hex-decode.default(bytes/empty).decode }).is-error)        // trailing data
  println(try({ "3080".hex-decode.default(bytes/empty).decode }).is-error)          // indefinite length
  // PEM
  val pem = pem-encode(s, "TEST")
  println(pem.lines.head.default(""))
  println(pem-decode(pem, "TEST").map(hex))
  println(try({ pem-decode("-----BEGIN TEST-----\n!!!\n-----END TEST-----\n", "TEST") }).is-error)
