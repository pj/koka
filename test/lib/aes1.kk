// std/crypto/aes against FIPS-197, SP 800-38A and RFC 6070 / hashlib values
import std/crypto/aes
import std/text/encoding

fun hex( s : string ) : bytes
  s.hex-decode.default(bytes/empty)

fun check( name : string, got : bytes, expected : string ) : console ()
  println(name ++ ": " ++ (if got.hex-encode == expected then "ok" else "MISMATCH " ++ got.hex-encode))

fun main()
  val pt = hex("00112233445566778899aabbccddeeff")
  check("aes-128", aes-ecb-encrypt(hex("000102030405060708090a0b0c0d0e0f"), pt), "69c4e0d86a7b0430d8cdb78070b4c55a")
  check("aes-192", aes-ecb-encrypt(hex("000102030405060708090a0b0c0d0e0f1011121314151617"), pt), "dda97ca4864cdfe06eaf70a0ec0d7191")
  check("aes-256", aes-ecb-encrypt(hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"), pt), "8ea2b7ca516745bfeafc49904b496089")
  val key = hex("2b7e151628aed2a6abf7158809cf4f3c")
  val iv = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
  val msg = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
  check("ctr", aes-ctr(key, iv, msg), "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff")
  println(aes-ctr(key, iv, aes-ctr(key, iv, "a message of any length".bytes)).string)
  // the little-endian counter differs from the second block on
  val le = aes-ctr-le(key, hex("01000000000000000000000000000000"), msg).hex-encode
  val be = aes-ctr(key, hex("01000000000000000000000000000000"), msg).hex-encode
  println((le.slice.take(32).string == be.slice.take(32).string, le != be))
  check("pbkdf2-sha1 1", pbkdf2-sha1("password".bytes, "salt".bytes, 1, 20), "0c60c80f961f0e71f3a9b524af6012062fe037a6")
  check("pbkdf2-sha1 4096", pbkdf2-sha1("password".bytes, "salt".bytes, 4096, 20), "4b007901b765489abead49d926f721d065a429c1")
  check("pbkdf2-sha1 25 bytes", pbkdf2-sha1("passwordPASSWORDpassword".bytes, "saltSALTsaltSALTsaltSALTsaltSALTsalt".bytes, 4096, 25), "3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038")
  check("pbkdf2-sha256 4096", pbkdf2-sha256("password".bytes, "salt".bytes, 4096, 32), "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
  println((try({ aes-ctr("short".bytes, iv, msg) }).is-error, try({ aes-ecb-encrypt(key, "odd".bytes) }).is-error))
  println(xor-bytes(hex("ff00ff"), hex("0f0f")).hex-encode)
  val r1 = random-bytes(16)
  println((r1.length, r1.hex-encode != random-bytes(16).hex-encode))
