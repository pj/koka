/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* File system operations.

   This module re-exports `std/os/path`, `std/os/file` and `std/os/dir` and
   adds binary files, appending, file metadata, removing and renaming,
   permissions, temporary files and directories, glob matching, and a lazy
   directory walk.

   ```
   import std/os/fs

   fun main()
     with-temp-dir fn(dir)
       val f = dir / "hello.txt"
       write-text-file(f, "hello")
       append-text-file(f, " world")
       println(read-text-file(f))          // hello world
       println(file-info(f).size)          // 11
       println(glob(dir, "*.txt"))
   ```

   On the C backend this uses POSIX functions; on Windows most of the new
   operations are not yet supported. On the JavaScript backend it requires
   Node.js.
*/
module std/os/fs

pub import std/os/path
pub import std/os/file
pub import std/os/dir
import std/core/undiv
import std/core/seq
import std/num/float64

extern import
  c  file "fs-inline.c"
  js file "fs-inline.js"

// ----------------------------------------------------------------------------
// Binary files and appending
// ----------------------------------------------------------------------------

// Read a whole file as bytes.
pub fun read-file( path : path ) : <fsys,exn> bytes
  match prim-read-file(path.string)
    Error(exn) -> throw-exn(exn.prepend("unable to read file " ++ path.show))
    Ok(content) -> content

// Write bytes to a file, replacing its contents. Creates the parent directory if needed (and `create-dir` is `True`).
pub fun write-file( path : path, content : bytes, create-dir : bool = True ) : <fsys,exn> ()
  if create-dir then ensure-dir(path.nobase)
  match prim-write-file(path.string, content, False)
    Error(exn) -> throw-exn(exn.prepend("unable to write file " ++ path.show))
    _ -> ()

// Append bytes to a file (creating it if it does not exist).
pub fun append-file( path : path, content : bytes ) : <fsys,exn> ()
  match prim-write-file(path.string, content, True)
    Error(exn) -> throw-exn(exn.prepend("unable to append to file " ++ path.show))
    _ -> ()

// Append text (as UTF-8) to a file (creating it if it does not exist).
pub fun append-text-file( path : path, content : string ) : <fsys,exn> ()
  append-file(path, content.bytes)

// Read a text file as a list of lines (without the line terminators).
pub fun read-lines( path : path ) : <fsys,exn> list<string>
  val content = read-text-file(path)
  val lines = content.split("\n").map(fn(l) match l.ends-with("\r") { Just(sl) -> sl.string; Nothing -> l })
  match lines.split-last
    Just2(init, "") -> init
    _ -> lines

// Write a list of lines to a text file (each followed by a newline).
pub fun write-lines( path : path, lines : list<string> ) : <fsys,exn> ()
  write-text-file(path, lines.map(fn(l) l ++ "\n").join)

// ----------------------------------------------------------------------------
// Metadata
// ----------------------------------------------------------------------------

// The kind of a file system entry.
pub type file-kind
  File
  Directory
  Symlink
  Other

pub fun file-kind/show( k : file-kind ) : string
  match k
    File -> "file"
    Directory -> "directory"
    Symlink -> "symlink"
    Other -> "other"

pub fun file-kind/(==)( k1 : file-kind, k2 : file-kind ) : bool
  k1.show == k2.show

// Information about a file system entry.
pub struct file-info
  kind : file-kind
  size : int                  // size in bytes
  modified : float64          // last modification time in seconds since the Unix epoch (1970-01-01 UTC)
  permissions : int           // permission bits (e.g. `0o644` is `420`)

pub fun file-info/show( fi : file-info ) : string
  "file-info(" ++ fi.kind.show ++ ", size=" ++ fi.size.show ++ ", permissions=0o" ++ fi.permissions.show-octal ++ ")"

fun show-octal( i : int ) : string
  if i < 8 then i.show else show-octal(pretend-decreasing(i / 8)) ++ (i % 8).show

fun to-file-info( v : vector<int> ) : file-info
  val kind = match v.at(0).default(3)
    0 -> File
    1 -> Directory
    2 -> Symlink
    _ -> Other
  File-info(kind, v.at(1).default(0), v.at(2).default(0).float64 + v.at(3).default(0).float64 / 1.0e9, v.at(4).default(0))

// Get information about a file or directory (following symbolic links).
pub fun file-info( path : path ) : <fsys,exn> file-info
  match prim-stat(path.string, True)
    Error(exn) -> throw-exn(exn.prepend("unable to get file information for " ++ path.show))
    Ok(v) -> v.to-file-info

// Get information about a file system entry without following symbolic links.
pub fun link-info( path : path ) : <fsys,exn> file-info
  match prim-stat(path.string, False)
    Error(exn) -> throw-exn(exn.prepend("unable to get file information for " ++ path.show))
    Ok(v) -> v.to-file-info

// Does a file, directory, or other entry exist at `path`? (A broken symbolic link counts as existing.)
pub fun path-exists( path : path ) : fsys bool
  match prim-stat(path.string, False)
    Ok -> True
    Error -> False

// Is `path` a symbolic link?
pub fun path/is-symlink( path : path ) : fsys bool
  match prim-stat(path.string, False)
    Ok(v) -> v.at(0) == Just(2)
    Error -> False

// The size of a file in bytes.
pub fun file-size( path : path ) : <fsys,exn> int
  file-info(path).size

// Set the permission bits of a file or directory (e.g. `0o755` is `493`).
pub fun set-permissions( path : path, mode : int ) : <fsys,exn> ()
  match prim-chmod(path.string, mode)
    Error(exn) -> throw-exn(exn.prepend("unable to set permissions of " ++ path.show))
    _ -> ()

// ----------------------------------------------------------------------------
// Removing, renaming, and creating
// ----------------------------------------------------------------------------

// Remove a file (or symbolic link).
pub fun remove-file( path : path ) : <fsys,exn> ()
  match prim-remove-file(path.string)
    Error(exn) -> throw-exn(exn.prepend("unable to remove " ++ path.show))
    _ -> ()

// Rename (move) a file or directory. Replaces `to` if it is an existing file.
pub fun rename( from : path, to : path ) : <fsys,exn> ()
  match prim-rename(from.string, to.string)
    Error(exn) -> throw-exn(exn.prepend("unable to rename " ++ from.show ++ " to " ++ to.show))
    _ -> ()

// Create a directory. Raises an exception if it already exists or if the
// parent directory does not exist (use `ensure-dir` to create all parents).
pub fun create-dir( dir : path ) : <fsys,exn> ()
  match prim-create-dir(dir.string)
    Error(exn) -> throw-exn(exn.prepend("unable to create directory " ++ dir.show))
    _ -> ()

// Remove an empty directory.
pub fun remove-dir( dir : path ) : <fsys,exn> ()
  match prim-remove-dir(dir.string)
    Error(exn) -> throw-exn(exn.prepend("unable to remove directory " ++ dir.show))
    _ -> ()

// Remove a directory and everything in it. Symbolic links are removed but
// not followed. Does nothing if `dir` does not exist.
pub fun remove-dir-all( dir : path ) : <fsys,pure> ()
  match prim-stat(dir.string, False)
    Ok(v) | v.at(0) == Just(1) ->
      list-directory(dir).foreach fn(p)
        if p.is-symlink || !p.is-directory then remove-file(p) else remove-dir-all(p)
      remove-dir(dir)
    Ok -> remove-file(dir)
    Error -> ()

// Change the current working directory.
pub fun set-cwd( dir : path ) : <fsys,exn> ()
  match prim-set-cwd(dir.string)
    Error(exn) -> throw-exn(exn.prepend("unable to change directory to " ++ dir.show))
    _ -> ()

// Create a new, unique, empty temporary file (in `tempdir()` by default)
// and return its path. The caller is responsible for removing it.
pub fun create-temp-file( name-prefix : string = "koka-", parent : path = tempdir() ) : io path
  match prim-temp-file((parent / name-prefix.path).string)
    Error(exn) -> throw-exn(exn.prepend("unable to create a temporary file"))
    Ok(p) -> p.path

// Create a new, unique, empty temporary directory (in `tempdir()` by default)
// and return its path. The caller is responsible for removing it.
pub fun create-temp-dir( name-prefix : string = "koka-", parent : path = tempdir() ) : io path
  match prim-temp-dir((parent / name-prefix.path).string)
    Error(exn) -> throw-exn(exn.prepend("unable to create a temporary directory"))
    Ok(p) -> p.path

// Run `action` with a fresh temporary directory that is removed afterwards.
pub fun with-temp-dir( action : path -> <io|e> a, name-prefix : string = "koka-" ) : <io|e> a
  val dir = create-temp-dir(name-prefix)
  with finally { remove-dir-all(dir) }
  action(dir)

// ----------------------------------------------------------------------------
// Glob patterns
// ----------------------------------------------------------------------------

// Match a file name against a glob pattern. Supports `*` (any sequence of
// characters), `?` (any single character), and `[abc]`, `[a-z]` and `[!abc]`
// character classes.
pub fun glob-match( pattern : string, name : string ) : bool
  pretend-no-div { glob-chars(pattern.list, name.list) }

fun glob-chars( ps : list<char>, cs : list<char> ) : div bool
  match ps
    Nil -> cs.is-empty
    Cons('*', pp) -> glob-chars(pp, cs) || glob-star(ps, cs)
    Cons('?', pp) -> match cs
      Cons(_, cc) -> glob-chars(pp, cc)
      Nil -> False
    Cons('[', pp) -> match cs
      Cons(c, cc) -> match glob-class(pp, c)
        Just((ok, rest)) -> ok && glob-chars(rest, cc)
        Nothing -> c == '[' && glob-chars(pp, cc)
      Nil -> False
    Cons(p, pp) -> match cs
      Cons(c, cc) -> p == c && glob-chars(pp, cc)
      Nil -> False

// `*` consumes one more character
fun glob-star( ps : list<char>, cs : list<char> ) : div bool
  match cs
    Cons(_, cc) -> glob-chars(ps, cc)
    Nil -> False

// parse a character class after `[`; returns whether `c` matches and the rest of the pattern
fun glob-class( ps : list<char>, c : char ) : maybe<(bool, list<char>)>
  val (negate, ps1) = match ps
    Cons('!', pp) -> (True, pp)
    Cons('^', pp) -> (True, pp)
    _ -> (False, ps)
  match ps1.split-class
    Just((items, rest)) ->
      val found = items.any fn((lo, hi)) c >= lo && c <= hi
      Just((found != negate, rest))
    Nothing -> Nothing

fun split-class( ps : list<char> ) : maybe<(list<(char,char)>, list<char>)>
  match ps
    Cons(']', rest) -> Just(([], rest))
    Cons(lo, Cons('-', Cons(hi, rest))) | hi != ']' ->
      split-class(rest).map(fn((xs, r)) (Cons((lo, hi), xs), r))
    Cons(lo, rest) -> split-class(rest).map(fn((xs, r)) (Cons((lo, lo), xs), r))
    Nil -> Nothing

// Find all paths under `dir` whose path relative to `dir` matches `pattern`.
// A `**` segment matches any number of directories, for example
// `glob("src".path, "**/*.kk")`. The results are sorted.
pub fun glob( dir : path, pattern : string ) : <fsys,pure> list<path>
  val segs = pattern.split("/").filter(fn(s) !s.is-empty)
  glob-segs(dir, segs).map(string).sort.dedup.map(path)

fun glob-segs( dir : path, segs : list<string> ) : <fsys,pure> list<path>
  match segs
    Nil -> [dir]
    Cons("**", rest) ->
      val here = glob-segs(dir, rest)
      val subs = list-directory(dir).filter(fn(p) p.is-directory && !p.is-symlink).flatmap(fn(d) glob-segs(d, segs))
      here ++ subs
    Cons(seg, rest) ->
      val matches = list-directory(dir).filter(fn(p) glob-match(seg, p.nodir.string))
      if rest.is-empty then matches
      else matches.filter(is-directory).flatmap(fn(d) glob-segs(d, rest))

// ----------------------------------------------------------------------------
// Walking a directory tree
// ----------------------------------------------------------------------------

// Lazily walk the directory tree under `dir`, depth first. Every file and
// directory below `dir` (but not `dir` itself) is produced once, with the
// entries of each directory in sorted order and a directory just before its
// contents. Directories are read only when the walk reaches them, so a walk
// that is stopped early (with `take`, `find`, ...) reads no further.
//
// A directory for which `prune` returns `True` is produced but not entered.
// Symbolic links to directories are not followed unless `follow-symlinks` is
// set; `max-depth` limits how deep the walk goes (1 lists only `dir` itself).
//
// ```
// walk("src".path, prune = fn(p) p.nodir.string == ".git")
//   .filter(fn(p) p.extname == "kk")
//   .foreach(println)
// ```
pub fun walk( dir : path, prune : path -> bool = fn(_) False, max-depth : int = 1000, follow-symlinks : bool = False ) : seq<<fsys,exn|e>,path>
  generate
    walk-dir(dir, prune, max-depth, follow-symlinks)

fun walk-dir( dir : path, prune : path -> bool, depth : int, follow : bool ) : <yield<path>,fsys,exn,div> ()
  if depth > 0 then
    list-directory(dir).sort-on(path/string).foreach fn(p)
      yield(p)
      if p.is-directory && (follow || !p.is-symlink) && !prune(p) then
        walk-dir(p, prune, depth - 1, follow)

// ----------------------------------------------------------------------------
// Primitives
// ----------------------------------------------------------------------------

extern prim-read-file( path : string ) : fsys error<bytes>
  c  "kk_os_read_file_bytes"
  js "_read_file_bytes"

extern prim-write-file( path : string, content : bytes, append : bool ) : fsys error<()>
  c  "kk_os_write_file_bytes"
  js "_write_file_bytes"

extern prim-stat( path : string, follow : bool ) : fsys error<vector<int>>
  c  "kk_os_stat_prim"
  js "_stat_prim"

extern prim-remove-file( path : string ) : fsys error<()>
  c  "kk_os_remove_file_prim"
  js "_remove_file_prim"

extern prim-rename( from : string, to : string ) : fsys error<()>
  c  "kk_os_rename_prim"
  js "_rename_prim"

extern prim-chmod( path : string, mode : int ) : fsys error<()>
  c  "kk_os_chmod_prim"
  js "_chmod_prim"

extern prim-temp-file( pre : string ) : fsys error<string>
  c  "kk_os_temp_file_prim"
  js "_temp_file_prim"

extern prim-create-dir( path : string ) : fsys error<()>
  c  "kk_os_create_dir_prim"
  js "_create_dir_prim"

extern prim-remove-dir( path : string ) : fsys error<()>
  c  "kk_os_remove_dir_prim"
  js "_remove_dir_prim"

extern prim-set-cwd( path : string ) : fsys error<()>
  c  "kk_os_set_cwd_prim"
  js "_set_cwd_prim"

extern prim-temp-dir( pre : string ) : fsys error<string>
  c  "kk_os_temp_dir_prim"
  js "_temp_dir_prim"
