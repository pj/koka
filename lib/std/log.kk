/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Structured logging as an effect.

   Code logs through the `log` effect; the handler decides where messages go
   and which levels are shown. Libraries can log without choosing an output.

   ```
   import std/log

   fun process( items : list<int> ) : log ()
     log-info("processing", [("count", items.length.show)])
     if items.is-empty then log-warn("nothing to do")

   fun main()
     with log-to-stderr(min-level = Debug)
     process([1,2,3])
   ```
*/
module std/log

import std/os/io
import std/data/json

// Log levels in increasing order of severity.
pub type level
  Debug
  Info
  Warn
  Error

pub fun level/int( l : level ) : int
  match l
    Debug -> 0
    Info -> 1
    Warn -> 2
    Error -> 3

pub fun level/show( l : level ) : string
  match l
    Debug -> "DEBUG"
    Info -> "INFO"
    Warn -> "WARN"
    Error -> "ERROR"

pub fun level/(>=)( l1 : level, l2 : level ) : bool
  l1.int >= l2.int

// A log entry.
pub struct entry
  level : level
  message : string
  fields : list<(string, string)>

pub fun entry/show( e : entry ) : string
  e.level.show ++ " " ++ e.message ++ e.fields.map(fn((k,v)) " " ++ k ++ "=" ++ v.show-field).join

fun show-field( v : string ) : string
  if v.is-empty || v.list.any(fn(c) c == ' ' || c == '"' || c == '=') then v.show else v

// The logging effect.
pub effect log
  fun log-entry( e : entry ) : ()

// Log a message at the given level with optional key-value fields.
pub fun log-message( level : level, message : string, fields : list<(string, string)> = [] ) : log ()
  log-entry(Entry(level, message, fields))

pub fun log-debug( message : string, fields : list<(string, string)> = [] ) : log ()
  log-message(Debug, message, fields)

pub fun log-info( message : string, fields : list<(string, string)> = [] ) : log ()
  log-message(Info, message, fields)

pub fun log-warn( message : string, fields : list<(string, string)> = [] ) : log ()
  log-message(Warn, message, fields)

pub fun log-error( message : string, fields : list<(string, string)> = [] ) : log ()
  log-message(Error, message, fields)

// Add fields to every message logged by `action`.
pub fun with-log-fields( extra : list<(string, string)>, action : () -> <log,log|e> a ) : <log|e> a
  with fun log-entry(e) log-entry(e(fields = e.fields ++ extra))
  action()

// Write log messages at or above `min-level` to standard error as text lines,
// for example `INFO processing count=3`.
pub fun log-to-stderr( action : () -> <log,console|e> a, min-level : level = Info ) : <console|e> a
  with fun log-entry(e) if e.level >= min-level then eprintln(e.show)
  action()

// Write log messages at or above `min-level` to standard error as JSON lines,
// for example `{"level":"INFO","message":"processing","count":"3"}`.
pub fun log-to-stderr-json( action : () -> <log,console|e> a, min-level : level = Info ) : <console|e> a
  with fun log-entry(e)
    if e.level >= min-level then
      val j = json-object([("level", e.level.show.json), ("message", e.message.json)] ++ e.fields.map(fn((k,v)) (k, v.json)))
      eprintln(j.stringify)
  action()

// Write log messages at or above `min-level` to standard output (as text lines).
pub fun log-to-stdout( action : () -> <log,console|e> a, min-level : level = Info ) : <console|e> a
  with fun log-entry(e) if e.level >= min-level then println(e.show)
  action()

// Collect all log entries (in order) together with the result of `action`.
pub fun log-collect( action : () -> <log|e> a ) : e (a, list<entry>)
  var entries := []
  with fun log-entry(e) entries := Cons(e, entries)
  val x = action()
  (x, entries.reverse)

// Discard all log messages.
pub fun log-ignore( action : () -> <log|e> a ) : e a
  with fun log-entry(_) ()
  action()
