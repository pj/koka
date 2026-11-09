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
