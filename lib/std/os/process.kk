/*---------------------------------------------------------------------------
  Copyright 2012-2021, Microsoft Research, Daan Leijen.
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Run processes.

   Use `run` to run a program with a list of arguments (without going through
   the shell), capturing its exit code, standard output and standard error:

   ```
   val res = run("git", ["status", "--short"])
   if res.exit-code == 0 then println(res.stdout)
   ```

   Use `run-output` when you only need the output and want an exception if the
   program fails. `run-system` and `run-system-read` run a command line through
   the shell.
*/
module std/os/process

import std/os/path
import std/os/env

extern import
  c  file "process-inline.c"
  js file "process-inline.js"

// Run a command in the shell and return its output as a string.
pub extern run-system-read( cmd : string ) : io error<string>
  c  "kk_os_run_command_error"
  js "_run_command_error"

// Run a command in the shell; returns the exit code.
pub extern run-system( cmd : string ) : io int
  c  "kk_os_run_system_prim"
  js "_run_system"

// The result of running a process.
pub struct process-result
  exit-code : int        // the exit code (128+N if the process was killed by signal N)
  stdout : string        // captured standard output (decoded as UTF-8)
  stderr : string        // captured standard error (decoded as UTF-8)
  stdout-bytes : bytes   // captured standard output as raw bytes

// Did the process exit with code 0?
pub fun is-success( r : process-result ) : bool
  r.exit-code == 0

pub fun process-result/show( r : process-result ) : string
  "process-result(exit-code=" ++ r.exit-code.show ++ ", stdout=" ++ r.stdout.show ++ ", stderr=" ++ r.stderr.show ++ ")"

// Run program `cmd` with arguments `args` (not through the shell) and wait for
// it to finish. The program is found using the `PATH` environment variable.
//
// - `input`: text fed to the standard input of the process.
// - `cwd`: the working directory of the process (default: the current directory).
// - `env`: extra environment variables, added to (or overriding) the current environment.
//
// Raises an exception if the program cannot be started; a non-zero exit code
// is returned in the result.
pub fun run( cmd : string, args : list<string> = [], input : string = "", cwd : path = "".path,
             env : list<(string,string)> = [] ) : io process-result
  run-bytes(cmd, args, input.bytes, cwd, env)

// Like `run`, but feeds raw `input` bytes to the standard input of the process.
pub fun run-bytes( cmd : string, args : list<string> = [], input : bytes = bytes/empty, cwd : path = "".path,
                   env : list<(string,string)> = [] ) : io process-result
  val envs = if env.is-empty then [] else
               val extra-names = env.map(fn((n,_)) n)
               val base = get-env().filter(fn((n,_)) !extra-names.any(fn(m) m == n))
               (base ++ env).map(fn((n,v)) n ++ "=" ++ v)
  match prim-spawn(cmd, args.vector, input, cwd.string, envs.vector)
    Error(exn) -> throw-exn(exn.prepend("unable to run " ++ cmd.show))
    Ok((code, out, err)) -> Process-result(code, out.string, err.string, out)

// Run a program and return its standard output. Raises an exception (including
// the standard error output) if the program exits with a non-zero exit code.
pub fun run-output( cmd : string, args : list<string> = [], input : string = "", cwd : path = "".path ) : io string
  val r = run(cmd, args, input, cwd)
  if r.exit-code != 0 then throw(cmd ++ " failed with exit code " ++ r.exit-code.show ++ (if r.stderr.is-empty then "" else ": " ++ r.stderr))
  r.stdout

extern prim-spawn( cmd : string, args : vector<string>, input : bytes, cwd : string, env : vector<string> ) : io error<(int,bytes,bytes)>
  c  "kk_os_spawn_prim"
  js "_spawn_prim"
