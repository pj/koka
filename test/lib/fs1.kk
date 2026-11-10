import std/os/fs
import std/num/float64

fun main()
  with-temp-dir fn(dir)
    val f = dir / "hello.txt"
    write-text-file(f, "hello")
    append-text-file(f, " world\nsecond line\n")
    println(read-text-file(f).show)
    println(read-lines(f))
    val info = file-info(f)
    println((info.kind.show, info.size, f.file-size, info.modified > 1.0e9))
    println((f.path-exists, (dir / "nope").path-exists, dir.path-exists, f.is-symlink))
    // binary
    val b = f.nobase / "data.bin"
    write-file(b, [0,1,2,255,254].vector.bytes)
    append-file(b, [7].vector.bytes)
    println(read-file(b).list)
    // rename and remove
    val g = dir / "renamed.txt"
    rename(f, g)
    println((f.path-exists, g.path-exists))
    remove-file(g)
    println(g.path-exists)
    // permissions
    // (only the owner's write bit is portable: Windows has just a read-only attribute)
    set-permissions(b, 0x100)   // 0o400
    val ro = file-info(b).permissions
    set-permissions(b, 0x1C0)   // 0o700
    println(((ro / 128) % 2 == 0, (file-info(b).permissions / 128) % 2 == 1))
    // directories and glob
    ensure-dir(dir / "src" / "sub")
    create-dir(dir / "empty")
    write-text-file(dir / "src" / "a.kk", "a")
    write-text-file(dir / "src" / "b.txt", "b")
    write-text-file(dir / "src" / "sub" / "c.kk", "c")
    println(glob(dir, "src/*.kk").map(fn(p) p.nodir.string))
    println(glob(dir, "**/*.kk").map(fn(p) p.nodir.string))
    println(glob(dir, "src/[ab].*").map(fn(p) p.nodir.string))
    remove-dir(dir / "empty")
    println((dir / "empty").path-exists)
    println(catch(fn(_) "error: cannot create existing dir", { create-dir(dir / "src"); "created" }))
    remove-dir-all(dir / "src")
    println((dir / "src").path-exists)
    val t = create-temp-file("kt-", dir)
    println((t.path-exists, t.nodir.string.starts-with("kt-").is-just))
    // working directory
    val old = cwd()
    set-cwd(dir)
    println(cwd().realpath.string == dir.realpath.string)
    set-cwd(old)
    println(catch(fn(e) "read error caught", { read-file(dir / "missing").length.show }))
  println(["*.kk", "a?c", "[a-c]x", "[!a]x", "*"].map(fn(p) (glob-match(p, "abc.kk"), glob-match(p, "abc"), glob-match(p, "bx"))))
