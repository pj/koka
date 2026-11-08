// BLAKE2b, BLAKE2s and BLAKE3 against reference values (Python's hashlib and b3sum)
import std/crypto/hash
import std/text/encoding

fun pat( n : int ) : bytes
  list(0, n - 1).map(fn(i) i % 251).vector.bytes

fun check( name : string, got : bytes, expected : string ) : console ()
  println(name ++ ": " ++ (if got.hex-encode == expected then "ok" else "MISMATCH " ++ got.hex-encode))

fun main()
  val key64 = list(0, 63).vector.bytes
  val key32 = list(0, 31).vector.bytes
  val inputs = [("empty", bytes/empty), ("abc", "abc".bytes), ("pat 1000", pat(1000)), ("pat 5000", pat(5000)), ("pat 100003", pat(100003))]
  val b2b = ["786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce",
             "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923",
             "c11e1c0340bd7e5a1b275f1230c962fad215ecb1391486e74e31b960a2f2996381a5fad092da06841d5f26e38f6ecfeaf441acbcd1c2de61aef121e7927175f5",
             "e0544a2083f83329af4c725e0cf8805ce26d686a6bc33bfd2e29d5c1b5f9a889c44f1769e496e3586dae86e56c195908d6aa1d0e2cadad635902a37e812681ca",
             "ef1e2a1f9f45fd9fc8d9d8210b8c7c4d30a99982fdfab30751bcdf1ff485d307d4fca521e936d7bf7dc6f1bd6d701af433e41a14c6630ebed05d96e71caae0ec"]
  val b2s = ["69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9",
             "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982",
             "1c067a5e746fb0f6734efac9a8cdb0e11061f0077f255184365c690115392501",
             "5b73fde71a575695f52be841b2673288e9e797465cec0ae40c231d97810d8da5",
             "aaa671ea160c8561b7c9ee0d7e4d394965f85416113db682a9b27c193ba2ca63"]
  val b2b-keyed = ["15efac5a414effae1c5bc667974437c08cb07465", "f3464811aec9776024bd78c73dbaad63a62c509b",
                   "63c649f635ecae0b81d38d13e7c726aabfa75db3", "46ccdd66ded321d09e0fe0f21fbac02fcc861d7a",
                   "382d405d1921440a7902e8e5c88076511ca05f18"]
  val b2s-keyed = ["9536f9b267655743dee97b8a670f9f53", "61ba5f165c194692e09d12520cc4c74a", "8a0c93d51ede746600ef0dd2b32d6fb3",
                   "5bb3f9c16c867cc9b5ed68f415ee3658", "ffdd37c6b82d8aaa8dc10f8a2d053828"]
  zip(inputs, zip(zip(b2b, b2s), zip(b2b-keyed, b2s-keyed))).foreach fn(((name, d), ((eb, es), (ebk, esk))))
    check("blake2b " ++ name, d.blake2b, eb)
    check("blake2s " ++ name, d.blake2s, es)
    check("blake2b keyed " ++ name, d.blake2b(20, key64), ebk)
    check("blake2s keyed " ++ name, d.blake2s(16, key32), esk)
  check("blake2b keyed exact block", pat(128).blake2b(key = "k".bytes), "802cc68655d32a38df2144634e8cf5070fb087c9047c2861e6df3f773df80ba7189281fe78b2e64a4da9796c635d5b37fcf7c9ca575b2e891e24e5ca024b3466")
  check("blake2s exact block", pat(64).blake2s, "56f34e8b96557e90c1f24b52d0c89d51086acf1b00f634cf1dde9233b8eaaa3e")

  val b3 = [("empty", 0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
            ("abc", -1, "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"),
            ("pat 1000", 1000, "b43670a52d1af24abdac5d2c3ed19ff4e62b60a618e823ad555888b1b0b91cff"),
            ("pat 1024", 1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"),
            ("pat 1025", 1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"),
            ("pat 2048", 2048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a"),
            ("pat 3072", 3072, "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2"),
            ("pat 5000", 5000, "ee78d92070de3df1c57c37002abf0a6b1a6589acdeef4d8ffac7cf3d9e8f2836"),
            ("pat 100003", 100003, "ecbf9ff05e2ec5fd331a6fb97fa198df8e18b631c7abca6e8ebaa3bf5a5c0493")]
  b3.foreach fn((name, n, expected))
    val d = if n < 0 then "abc".bytes else pat(n)
    check("blake3 " ++ name, d.blake3, expected)
  check("blake3 100 bytes", "abc".bytes.blake3(100), "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d851fb250ae7393f5d02813b65d521a0d492d9ba09cf7ce7f4cffd900f23374bf0bc08a1fb0b38ed276181ccbd9f7b7edbddf9f86404ad7929605f6ffa3fb1ac87983105f01")
  check("blake3 keyed empty", blake3-keyed(key32, bytes/empty), "73492b19995d71cdb1e9d74decc09809eb732f1b00bc95c27cb15f9dd4d6478f")
  check("blake3 keyed abc", blake3-keyed(key32, "abc".bytes), "6da54495d8152f2bcba87bd7282df70901cdb66b4448ed5f4c7bd2852b8b5532")
  check("blake3 keyed pat 5000", blake3-keyed(key32, pat(5000)), "3742909929a310dec551d9163c279136d6506f289f75c283c5df101108cd09e5")
  check("blake3 derive", blake3-derive-key("example.com 2026 test v1", pat(1000)), "700c8afca476767dfb971f1609f27f03aa97d825d796908cc8c21493f6a34848")
  check("blake3 derive 40", blake3-derive-key("ctx", "abc".bytes, 40), "51b03b2a289e3f32acf87f00c3620dd6cc2c29706de6f8184386550dab656d36ab65cbf4802691c7")
  println(try({ blake3-keyed("short".bytes, "abc".bytes) }).is-error)
  println(("abc".bytes.blake2b(1).length, "abc".bytes.blake2b(100).length, "abc".bytes.blake3(0).length))
