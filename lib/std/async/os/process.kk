/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Asynchronous child processes.

   Supported on the C backend (using libuv) and on Node.js.

   ```
   import std/async
   import std/async/os/process

   fun main()
     // run to completion, capturing the output
     val r = run-process("git", ["status", "--short"])
     println(r.stdout)

     // or talk to a running process
     with p = spawn("sort")
     p.write-stdin("banana\napple\n")
     p.close-stdin
     println(p.read-all-stdout.string)
     println(p.wait)
   ```

   Unlike `std/os/process`, these functions do not block other strands, and
   they can be cancelled (for example with `timeout`), in which case the
   child process is killed.
*/
module async/os/process

import std/core/undiv
import std/num/int32
import std/os/path
import std/os/env
pub import std/os/process
import async/async
import async/internal
import async/interleave
import async/os/net
import async/api/net
  [host=libc|jsnode] async/api/uv/net

// How a standard stream of a child process is connected.
pub type stdio-mode
  // A pipe that the parent reads from (stdout, stderr) or writes to (stdin).
  Pipe
  // Shared with the parent process.
  Inherit
  // Connected to the null device.
  Ignore

fun stdio-mode/code( m : stdio-mode ) : int32
  match m
    Pipe -> 0.int32
    Inherit -> 1.int32
    Ignore -> 2.int32

// A running (or exited) child process.
abstract struct process
  hnd : any
  stdin-pipe : maybe<tcp-socket>
  stdout-pipe : maybe<tcp-socket>
  stderr-pipe : maybe<tcp-socket>

// Start program `cmd` with arguments `args` (not through the shell). The
// program is found using the `PATH` environment variable.
//
// - `cwd`: the working directory of the process (default: the current directory).
// - `env`: extra environment variables, added to (or overriding) the current environment.
// - `stdin`, `stdout`, `stderr`: how each standard stream is connected (default: `Pipe`).
//
// The process must be closed with `close` (or use the scoped `with p = spawn(..)` form).
pub fun spawn( cmd : string, args : list<string> = [], cwd : path = "".path, env : list<(string,string)> = [],
               stdin : stdio-mode = Pipe, stdout : stdio-mode = Pipe, stderr : stdio-mode = Pipe ) : <async,io> process
  with try-exn-prepend("unable to run " ++ cmd.show)
  val envs = if env.is-empty then [] else
               val extra-names = env.map(fn((n,_)) n)
               val base = get-env().filter(fn((n,_)) !extra-names.any(fn(m) m == n))
               (base ++ env).map(fn((n,v)) n ++ "=" ++ v)
  val h = await("proc-spawn") fn(evloop, resume)
    proc-spawn-setup(evloop, cmd, args.vector, cwd.string, envs.vector, stdin.code, stdout.code, stderr.code, resume)
  fun take( i : int ) : async maybe<tcp-socket>
    val pipe = async-ioc { proc-take-stdio(h, i.int32) }
    match pipe
      Just(x) -> Just(@unsafe-tcp-socket(x))
      Nothing -> Nothing
  Process(h, take(0), take(1), take(2))

// Start a process, run `action` with it, and close it afterwards. If the
// process is still running at that point, it is killed.
pub fun scoped/spawn( cmd : string, args : list<string>, action : process -> <async,io|e> a,
                      cwd : path = "".path, env : list<(string,string)> = [],
                      stdin : stdio-mode = Pipe, stdout : stdio-mode = Pipe, stderr : stdio-mode = Pipe ) : <async,io|e> a
  val p = spawn(cmd, args, cwd, env, stdin, stdout, stderr)
  with finally { p.kill(9); p.close }
  action(p)

// Wait for the process to exit and return its exit code (128+N if it was killed by signal N).
pub fun wait( p : process ) : <async,exn> int
  await("proc-wait", fn(evloop, resume) proc-wait-setup(evloop, p.hnd, resume))

// Send a signal to the process (default `15`, SIGTERM). Does nothing if the process has already exited.
pub fun kill( p : process, signal : int = 15 ) : async ()
  async-ioc { proc-kill(p.hnd, signal.int32) }

// The operating system process id.
pub fun pid( p : process ) : async int
  async-ioc { proc-pid(p.hnd) }.int

// Close the pipes of the process and release it. This does not kill the
// process: use `kill` (and `wait`) first if needed.
pub fun process/close( p : process ) : async ()
  p.stdin-pipe.foreach(fn(s) s.close)
  p.stdout-pipe.foreach(fn(s) s.close)
  p.stderr-pipe.foreach(fn(s) s.close)
  async-ioc { proc-close(p.hnd) }

fun pipe( m : maybe<tcp-socket>, name : string ) : exn tcp-socket
  match m
    Just(s) -> s
    Nothing -> throw("process: " ++ name ++ " is not a pipe")

// Write bytes to the standard input of the process.
pub fun write-stdin( p : process, data : bytes ) : <async,exn> ()
  p.stdin-pipe.pipe("stdin").write-all(data)

// Write a string (as UTF-8) to the standard input of the process.
pub fun string/write-stdin( p : process, text : string ) : <async,exn> ()
  p.write-stdin(text.bytes)

// Close the standard input of the process (signalling the end of the input).
pub fun close-stdin( p : process ) : <async,exn> ()
  val s = p.stdin-pipe.pipe("stdin")
  s.shutdown-write
  s.close

// Read the next chunk of the standard output; empty bytes at the end of the output.
pub fun read-stdout( p : process ) : <async,exn> bytes
  p.stdout-pipe.pipe("stdout").read

// Read the next chunk of the standard error output; empty bytes at the end of the output.
pub fun read-stderr( p : process ) : <async,exn> bytes
  p.stderr-pipe.pipe("stderr").read

// Read the standard output until it is closed.
pub fun read-all-stdout( p : process ) : <async,exn> bytes
  p.stdout-pipe.pipe("stdout").read-all

// Read the standard error output until it is closed.
pub fun read-all-stderr( p : process ) : <async,exn> bytes
  p.stderr-pipe.pipe("stderr").read-all

// Run program `cmd` with arguments `args` (not through the shell), feeding it
// `input`, and wait for it to finish. Other strands keep running meanwhile.
// See `std/os/process/run` for the parameters. If the call is cancelled
// (for example by a `timeout`), the process is killed.
pub fun run-process( cmd : string, args : list<string> = [], input : string = "", cwd : path = "".path,
                     env : list<(string,string)> = [] ) : <async,io> process-result
  run-process-bytes(cmd, args, input.bytes, cwd, env)

// Like `run-process`, but feeds raw `input` bytes to the standard input of the process.
pub fun run-process-bytes( cmd : string, args : list<string> = [], input : bytes = bytes/empty, cwd : path = "".path,
                           env : list<(string,string)> = [] ) : <async,io> process-result
  with p = spawn(cmd, args, cwd = cwd, env = env)
  val ((out, err), _) = interleaved({
    interleaved({ p.read-all-stdout }, { p.read-all-stderr })
  }, {
    // the process may exit without reading its input
    catch(fn(_) (), { p.write-stdin(input) })
    catch(fn(_) (), { p.close-stdin })
  })
  val code = p.wait
  Process-result(code, out.string, err.string, out)

// Run a program and return its standard output. Raises an exception (including
// the standard error output) if the program exits with a non-zero exit code.
pub fun run-process-output( cmd : string, args : list<string> = [], input : string = "", cwd : path = "".path ) : <async,io> string
  val r = run-process(cmd, args, input, cwd)
  if r.exit-code != 0 then throw(cmd ++ " failed with exit code " ++ r.exit-code.show ++ (if r.stderr.is-empty then "" else ": " ++ r.stderr))
  r.stdout
