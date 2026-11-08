/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Standard input, standard error, and exiting.

   ```
   import std/os/io

   fun main()
     val input = read-stdin()
     if input.is-empty then
       eprintln("error: no input")
       exit(1)
     println(input.lines.length)
   ```
*/
module std/os/io

pub import std/io/stream

extern import
  c  file "io-inline.c"
  js file "io-inline.js"

// Print a string to standard error.
pub fun eprint( s : string ) : console ()
  prim-eprint(s)

// Print a string followed by a newline to standard error.
pub fun eprintln( s : string ) : console ()
  prim-eprint(s ++ "\n")

// Flush standard output and standard error.
pub fun flush() : console ()
  prim-flush()

// Read all of standard input (as UTF-8) until end-of-file.
pub fun read-stdin() : <console,exn> string
  match prim-read-stdin()
    Error(exn) -> throw-exn(exn.prepend("unable to read standard input"))
    Ok(s) -> s

// Read all lines of standard input (without line terminators).
pub fun read-stdin-lines() : <console,exn> list<string>
  val s = read-stdin()
  if s.is-empty then [] else
    val lines = s.split("\n").map(fn(l) match l.ends-with("\r") { Just(sl) -> sl.string; Nothing -> l })
    match lines.split-last
      Just2(init, "") -> init
      _ -> lines

// Standard input as a stream, read in chunks of at most `chunk-size` bytes
// as the input arrives. The stream is consumed as it is read (see `std/io/stream`).
//
// ```
// stdin-stream().lines.foreach fn(line)
//   println(line.to-upper)
// ```
pub fun stdin-stream( chunk-size : int = 65536 ) : byte-stream<<console,exn|e>>
  from-reader(fn() read-stdin-chunk(chunk-size))

// Read the next chunk of at most `max` bytes from standard input, as soon as
// some input is available. Returns empty bytes at the end of the input.
pub fun read-stdin-chunk( max : int = 65536 ) : <console,exn> bytes
  match prim-read-stdin-chunk(max)
    Error(exn) -> throw-exn(exn.prepend("unable to read standard input"))
    Ok(b) -> b

// Write bytes to standard output (after the text printed so far).
pub fun write-stdout( content : bytes ) : <console,exn> ()
  match prim-write-std(1, content)
    Error(exn) -> throw-exn(exn.prepend("unable to write to standard output"))
    _ -> ()

// Write bytes to standard error.
pub fun write-stderr( content : bytes ) : <console,exn> ()
  match prim-write-std(2, content)
    Error(exn) -> throw-exn(exn.prepend("unable to write to standard error"))
    _ -> ()

// Is standard input connected to a terminal?
pub fun stdin-is-tty() : console bool
  prim-is-tty(0)

// Is standard output connected to a terminal?
pub fun stdout-is-tty() : console bool
  prim-is-tty(1)

// Is standard error connected to a terminal?
pub fun stderr-is-tty() : console bool
  prim-is-tty(2)

// Exit the program immediately with the given exit code (flushing standard output first).
pub fun exit( code : int = 0 ) : io a
  prim-exit(code)
  throw("std/os/io/exit: unreachable")

extern prim-eprint( s : string ) : console ()
  c  "kk_os_eprint"
  js "_eprint"

extern prim-flush() : console ()
  c  "kk_os_flush"
  js "_flush"

extern prim-read-stdin() : console error<string>
  c  "kk_os_read_stdin"
  js "_read_stdin"

extern prim-read-stdin-chunk( max : int ) : console error<bytes>
  c  "kk_os_read_stdin_chunk"
  js "_read_stdin_chunk"

extern prim-write-std( fd : int, content : bytes ) : console error<()>
  c  "kk_os_write_std"
  js "_write_std"

extern prim-is-tty( fd : int ) : console bool
  c  "kk_os_is_tty"
  js "_is_tty"

extern prim-exit( code : int ) : io ()
  c  "kk_os_exit"
  js "_exit"
