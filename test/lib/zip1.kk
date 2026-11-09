// std/compress/zip, also against the zip and unzip tools
import std/compress/zip
import std/os/fs
import std/os/process

fun main()
  val text = "hello zip world\n".repeat(100)
  val archive = zip-write([zip-file("hello.txt", text.bytes), zip-file("docs/", bytes/empty),
                           zip-file("docs/raw.bin", list(0, 255).vector.bytes, compress = False),
                           zip-file("ünïcode.txt", "ok".bytes), Zip-entry("run.sh", "echo hi".bytes, unix-mode = 0x1ED)])
  println(archive.length < text.count)
  zip-read(archive).foreach fn(e)
    println((e.name, e.data.length, e.is-directory, e.compress, e.unix-mode.show-hex))
  println(zip-find(archive, "hello.txt").map(fn(e) e.data.string == text))
  println(zip-write([]).length)
  // errors
  println(try({ zip-read("not a zip".bytes) }).is-error)
  val corrupt = archive.subbytes(0, 40) ++ "X".bytes ++ archive.subbytes(41)
  println(match try({ zip-read(corrupt) }) { Error(e) -> e.message.contains("checksum") || e.message.contains("hello.txt"); Ok(_) -> False })
  // interoperability
  with-temp-dir fn(dir)
    val ours = dir / "ours.zip"
    write-file(ours, archive)
    println(run("unzip", ["-tq", ours.string]).stdout.starts-with("No errors detected").is-just)
    println(run("unzip", ["-p", ours.string, "hello.txt"]).stdout == text)
    write-text-file(dir / "a.txt", "from the zip tool\n".repeat(50))
    write-text-file(dir / "sub" / "b.txt", "nested")
    println(run("sh", ["-c", "cd " ++ dir.string ++ " && zip -qr theirs.zip a.txt sub"]).exit-code)
    zip-read(read-file(dir / "theirs.zip")).foreach fn(e)
      println((e.name, e.data.length, e.is-directory))
  // zip64, written and read
  val z64 = zip-write([zip-file("big-format.txt", text.bytes), zip-file("two.txt", "2".bytes)], zip64 = True)
  println(zip-read(z64).map(fn(e) (e.name, e.data.length)))
  // encryption: WinZip AES (all strengths) and ZipCrypto
  val secret = zip-write([zip-file("aes256.txt", text.bytes, password = "pw"), zip-file("aes128.txt", "small".bytes, password = "pw", encryption = Aes128),
                          zip-file("aes192.txt", "x".bytes, compress = False, password = "pw", encryption = Aes192),
                          zip-file("legacy.txt", text.bytes, password = "pw", encryption = Zip-crypto), zip-file("plain.txt", "open".bytes)])
  println(zip-read(secret, password = "pw").map(fn(e) (e.name, e.encryption.show, e.data.length, e.data.string == text)))
  println(match try({ zip-read(secret) }) { Error(e) -> e.message; Ok(_) -> "read without a password?" })
  println(match try({ zip-read(secret, password = "wrong") }) { Error(e) -> e.message; Ok(_) -> "read with a wrong password?" })
  with-temp-dir fn(dir)
    // our encrypted and zip64 archives with the tools
    val enc = dir / "enc.zip"
    write-file(enc, zip-write([zip-file("legacy.txt", text.bytes, password = "pw", encryption = Zip-crypto)]))
    println(run("unzip", ["-P", "pw", "-p", enc.string, "legacy.txt"]).stdout == text)
    val z = dir / "z64.zip"
    write-file(z, z64)
    println(run("unzip", ["-tq", z.string]).stdout.starts-with("No errors detected").is-just)
    // archives made by the tools
    write-text-file(dir / "a.txt", text)
    println(run("sh", ["-c", "cd " ++ dir.string ++ " && zip -q -P pw crypt.zip a.txt && zip -q -fz z64t.zip a.txt"]).exit-code)
    println(zip-read(read-file(dir / "crypt.zip"), password = "pw").map(fn(e) (e.name, e.encryption.show, e.data.string == text)))
    println(zip-read(read-file(dir / "z64t.zip")).map(fn(e) (e.name, e.data.string == text)))
