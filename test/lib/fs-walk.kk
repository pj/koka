// std/os/fs: lazy directory walk
import std/core/seq
import std/os/fs
import std/os/env

fun main()
  with-temp-dir fn(dir)
    write-text-file(dir / "b.txt", "")
    write-text-file(dir / "a/x.kk", "")
    write-text-file(dir / "a/y.txt", "")
    write-text-file(dir / "a/deep/z.kk", "")
    write-text-file(dir / ".git/config", "")
    create-dir(dir / "empty")
    fun rel( p : path ) : string
      p.string.slice.drop(dir.string.count + 1).string
    println(walk(dir).map(rel).list)
    println(walk(dir).filter(fn(p) p.extname == "kk").map(rel).list)
    println(walk(dir, prune = fn(p) p.nodir.string == ".git").map(rel).list)
    println(walk(dir, max-depth = 1).map(rel).list)
    println(walk(dir).filter(is-file).length)
    // stopping early does not read further directories: "zz" cannot be read
    write-text-file(dir / "zz/secret", "")
    set-permissions(dir / "zz", 0)
    println(walk(dir).find(fn(p) p.nodir.string == "x.kk").map(rel))
    // (Windows cannot make a directory unreadable)
    println(try { walk(dir).list.length }.either.is-left || get-os-name() == "windows")
    set-permissions(dir / "zz", 0x1ED)
    // a missing directory raises an exception when the walk starts
    println(try { walk(dir / "nope").list.length }.either.is-left)
