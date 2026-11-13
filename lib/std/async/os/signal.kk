/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Operating system signals.

   `wait-signal` waits (asynchronously) until the process receives one of the
   given signals. Together with `firstof` this gives a graceful shutdown:

   ```
   import std/async
   import std/async/os/net
   import std/async/os/http
   import std/async/os/signal

   fun main()
     val server = tcp-listen("127.0.0.1", 8080)
     firstof({ http-serve(server, fn(req) text-response(200, "hello")) }, {
       val sig = wait-signal([SIGINT, SIGTERM])
       println("stopping on " ++ sig.show)
     })
     server.close
   ```

   While a strand waits for a signal, the signal does not have its default
   effect (such as terminating the process on `SIGINT`). Between two calls of
   `wait-signal` it does. To handle a signal every time it arrives, use
   `with-signals`: for the whole scope, the signals are queued instead of
   having their default effect, and `next` takes them one at a time:

   ```
   with-signals([SIGHUP, SIGTERM]) fn(sigs)
     firstof({ serve() }, {
       while { sigs.next != SIGTERM } { reload-config() }
     })
   ```

   On the C backend this uses libuv; on the JavaScript backend Node's
   `process` signal events. On Windows only `SIGINT`, `SIGTERM` and `SIGBREAK`
   (`SIGHUP` here) can be waited for.
*/
module async/os/signal

import async/async
import async/internal
import async/channel
import async/api/signal
  [host=libc|jsnode] async/api/uv/signal

// A signal.
pub type signal
  SIGINT     // interrupt (Ctrl-C)
  SIGTERM    // termination request
  SIGHUP     // the terminal was closed (`SIGBREAK`, Ctrl-Break, on Windows)
  SIGQUIT    // quit (Ctrl-\)
  SIGUSR1    // user-defined signal 1
  SIGUSR2    // user-defined signal 2
  SIGWINCH   // the terminal window was resized
  SIGPIPE    // writing to a pipe or socket that is closed
  SIGCHLD    // a child process stopped or exited

fun code( sig : signal ) : int
  match sig
    SIGINT   -> 0
    SIGTERM  -> 1
    SIGHUP   -> 2
    SIGQUIT  -> 3
    SIGUSR1  -> 4
    SIGUSR2  -> 5
    SIGWINCH -> 6
    SIGPIPE  -> 7
    SIGCHLD  -> 8

pub fun signal/show( sig : signal ) : string
  match sig
    SIGINT   -> "SIGINT"
    SIGTERM  -> "SIGTERM"
    SIGHUP   -> "SIGHUP"
    SIGQUIT  -> "SIGQUIT"
    SIGUSR1  -> "SIGUSR1"
    SIGUSR2  -> "SIGUSR2"
    SIGWINCH -> "SIGWINCH"
    SIGPIPE  -> "SIGPIPE"
    SIGCHLD  -> "SIGCHLD"

pub fun signal/(==)( a : signal, b : signal ) : bool
  a.code == b.code

// The platform's number for the signal (such as 2 for `SIGINT`), or -1 if
// the platform does not have it. Use it with `std/async/os/process/kill`.
pub fun number( sig : signal ) : int
  signal-number(sig.code)

// Wait until the process receives one of the `signals`, and return it.
pub fun wait-signal( signals : list<signal> = [SIGINT, SIGTERM] ) : <async,exn> signal
  setup/await("wait-signal") fn(evloop, resume)
    arm(evloop, signals, resume)

// Set up a one-shot handler for each signal: the first one that arrives
// disposes the others and resumes.
fun arm( evloop : any, signals : list<signal>, resume : error<signal> -> ioc () ) : ioc error<() -> ioc ()>
  val disposers : ref<global,list<(int, () -> ioc ())>> = ref([])
  fun dispose-except( i : int ) : ioc ()
    val ds = !disposers
    disposers := []
    ds.foreach fn((j, d)) if j != i then d()
  val setups = signals.map-indexed fn(i, sig)
    (i, signal-setup(evloop, sig.code, fn() { dispose-except(i); resume(Ok(sig)) }))
  val oks = setups.flatmap fn((i, r)) match r
    Ok(d) -> [(i, d)]
    Error(_) -> []
  match setups.find-maybe(fn((_, r)) match r { Error(e) -> Just(e); _ -> Nothing })
    Just(e) ->
      oks.foreach(fn((_, d)) d())
      Error(e)
    Nothing ->
      if oks.is-nil then Error(Exception("wait-signal: no signals to wait for", ExnError))
      else
        disposers := oks
        Ok(fn() dispose-except(-1))

// Signals that are handled for a while (see `with-signals`).
abstract struct signal-handler
  received : channel<signal>

// Handle `signals` while `action` runs: every time one of them arrives it is
// queued (it does not have its default effect, such as terminating the
// process), and `next` returns the queued signals in order.
pub fun with-signals( signals : list<signal>, action : signal-handler -> <async,exn|e> a ) : <async,exn|e> a
  val ch : channel<signal> = channel()
  val disposers : ref<global,list<() -> ioc ()>> = async-ioc { ref([]) }
  with finally { async-ioc { dispose-all(disposers) } }
  if signals.is-nil then throw("with-signals: no signals to handle")
  do-sync(fn(evloop) watch-all(evloop, signals, ch, disposers), "with-signals")
  action(Signal-handler(ch))

// (a signature is needed: inferring the effect of reading the ref fails)
fun get-disposers( r : ref<global,list<() -> ioc ()>> ) : <read<global>,div> list<() -> ioc ()>
  !r

fun dispose-all( disposers : ref<global,list<() -> ioc ()>> ) : ioc ()
  val ds = get-disposers(disposers)
  disposers := []
  ds.foreach(fn(d) d())

fun watch-all( evloop : any, signals : list<signal>, ch : channel<signal>, disposers : ref<global,list<() -> ioc ()>> ) : ioc error<()>
  match signals
    Nil -> Ok(())
    Cons(sig, rest) ->
      match signal-watch(evloop, sig.code, fn() emit-io(ch, sig))
        Ok(d) ->
          disposers := Cons(d, get-disposers(disposers))
          watch-all(evloop, rest, ch, disposers)
        Error(e) -> Error(e)

// Wait for the next signal: the earliest queued one, or the next to arrive.
pub fun next( h : signal-handler ) : <async,ndet> signal
  h.received.receive

// The earliest queued signal, if any (without waiting).
pub fun try-next( h : signal-handler ) : <async,ndet> maybe<signal>
  h.received.try-receive

// Send a signal to the current process.
pub fun raise-signal( sig : signal ) : <async,exn> ()
  val res = async-ioc { signal-raise(sig.code) }
  match res
    Error(e) -> throw-exn(e)
    Ok(_) -> ()
