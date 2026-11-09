/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Threads and shared state: atomic integers, shared cells, mutexes and
   channels.

   ```
   import std/os/sync

   fun main()
     val hits = atomic(0)
     val results = channel()
     val workers = list(1, 4).map fn(w)
       spawn
         for(1, 1000) fn(_) hits.add(1)
         results.send(w * 10)
     workers.foreach(join)
     println(hits.load)                                  // 4000
     println(list(1, 4).map(fn(_) results.receive).sum)  // 100
   ```

   `spawn` runs a function on the thread pool of `std/os/task`. The function
   may use the effects that need no handler (`ndet`, `console` and `div`), so
   it can use the primitives here, but not exceptions or other effects
   handled by the caller. (Effect handlers inside spawned work, including
   `try`, are not safe in the current runtime: they can corrupt memory.) Values that are stored in or sent through these
   primitives are marked as shared between threads.

   All operations have the `ndet` effect, since their results depend on how
   threads are scheduled. Waiting operations (`receive`, `join`, a held
   mutex) block the thread: a task that waits for work that has not been
   scheduled yet can deadlock when every pool thread waits.

   On the C backend these are real threads (POSIX). The JavaScript backend
   has no threads: `spawn` runs the function immediately, and waiting for
   something that is not there yet raises an exception about a deadlock.
*/
module std/os/sync

extern import
  c  file "sync-inline.c"
  js file "sync-inline.js"

// ----------------------------------------------------------------------------
// Threads
// ----------------------------------------------------------------------------

// The result of a function running on another thread.
abstract struct future<a>( hnd : any )

// Run `work` on another thread.
pub noinline fun spawn( work : () -> <ndet,console,div> a ) : ndet future<a>
  Future(prim-spawn(work))

// Wait for the result.
pub fun join( f : future<a> ) : ndet a
  prim-join(f.hnd)

noinline extern prim-spawn( work : () -> <ndet,console,div> a ) : ndet any
  c  "kk_task_schedule"
  js "_sync_spawn"

noinline extern prim-join( p : any ) : ndet a
  c  "kk_promise_get"
  js "_sync_join"

// ----------------------------------------------------------------------------
// Atomic integers
// ----------------------------------------------------------------------------

// A 64-bit integer that threads can update atomically.
abstract struct atomic( hnd : any )

pub fun atomic( init : int = 0 ) : ndet atomic
  Atomic(prim-atomic-new(init))

pub fun load( a : atomic ) : ndet int
  prim-atomic-load(a.hnd)

pub fun store( a : atomic, i : int ) : ndet ()
  prim-atomic-store(a.hnd, i)

// Add `i` and return the new value.
pub fun add( a : atomic, i : int ) : ndet int
  prim-atomic-fetch-add(a.hnd, i) + i

// Add `i` and return the old value.
pub fun fetch-add( a : atomic, i : int ) : ndet int
  prim-atomic-fetch-add(a.hnd, i)

// Set the value to `i` and return the old value.
pub fun exchange( a : atomic, i : int ) : ndet int
  prim-atomic-exchange(a.hnd, i)

// Set the value to `desired` if it is `expected`; returns whether it was.
pub fun compare-exchange( a : atomic, expected : int, desired : int ) : ndet bool
  prim-atomic-cas(a.hnd, expected, desired)

// ----------------------------------------------------------------------------
// Shared cells
// ----------------------------------------------------------------------------

// A value that threads can read and replace (guarded by a mutex).
abstract struct shared<a>( hnd : any )

pub fun shared( init : a ) : ndet shared<a>
  Shared(prim-cell-new(init))

pub fun read( s : shared<a> ) : ndet a
  prim-cell-read(s.hnd)

pub fun write( s : shared<a>, x : a ) : ndet ()
  prim-cell-write(s.hnd, x)

// Replace the value `x` with `f(x)` atomically (other threads wait), and
// return the new value. `f` should be quick: it runs while the lock is held.
pub fun update( s : shared<a>, f : a -> a ) : ndet a
  prim-cell-update(s.hnd, f)

// ----------------------------------------------------------------------------
// Mutexes
// ----------------------------------------------------------------------------

// A mutual exclusion lock.
abstract struct mutex( hnd : any )

pub fun mutex() : ndet mutex
  Mutex(prim-mutex-new())

// Run `action` while holding the lock. The action cannot raise exceptions,
// so the lock is always released afterwards. (This uses no effect handler:
// handlers inside spawned work are not safe in the current runtime.)
pub fun with-lock( m : mutex, action : () -> <ndet,console,div> a ) : <ndet,console,div> a
  prim-mutex-lock(m.hnd)
  val x = action()
  prim-mutex-unlock(m.hnd)
  x

// ----------------------------------------------------------------------------
// Channels
// ----------------------------------------------------------------------------

// An unbounded first-in first-out queue between threads.
abstract struct channel<a>( hnd : any )

pub fun channel() : ndet channel<a>
  Channel(prim-chan-new())

// Add a value (never blocks).
pub fun send( ch : channel<a>, x : a ) : ndet ()
  prim-chan-send(ch.hnd, x)

// Take the first value, waiting until there is one.
pub fun receive( ch : channel<a> ) : ndet a
  prim-chan-receive(ch.hnd)

// Take the first value if there is one.
pub fun try-receive( ch : channel<a> ) : ndet maybe<a>
  prim-chan-try-receive(ch.hnd)

// The number of values waiting.
pub fun count( ch : channel<a> ) : ndet int
  prim-chan-count(ch.hnd)

// ----------------------------------------------------------------------------
// Primitives
// ----------------------------------------------------------------------------

extern prim-atomic-new( i : int ) : ndet any
  c  "kk_sync_atomic_new"
  js "_sync_atomic_new"

extern prim-atomic-load( a : any ) : ndet int
  c  "kk_sync_atomic_load"
  js "_sync_atomic_load"

extern prim-atomic-store( a : any, i : int ) : ndet ()
  c  "kk_sync_atomic_store"
  js "_sync_atomic_store"

extern prim-atomic-fetch-add( a : any, i : int ) : ndet int
  c  "kk_sync_atomic_fetch_add"
  js "_sync_atomic_fetch_add"

extern prim-atomic-exchange( a : any, i : int ) : ndet int
  c  "kk_sync_atomic_exchange"
  js "_sync_atomic_exchange"

extern prim-atomic-cas( a : any, expected : int, desired : int ) : ndet bool
  c  "kk_sync_atomic_cas"
  js "_sync_atomic_cas"

extern prim-mutex-new() : ndet any
  c  "kk_sync_mutex_new"
  js "_sync_mutex_new"

extern prim-mutex-lock( m : any ) : ndet ()
  c  "kk_sync_mutex_lock"
  js "_sync_mutex_lock"

extern prim-mutex-unlock( m : any ) : ndet ()
  c  "kk_sync_mutex_unlock"
  js "_sync_mutex_unlock"

extern prim-cell-new( x : a ) : ndet any
  c  "kk_sync_cell_new"
  js "_sync_cell_new"

extern prim-cell-read( c : any ) : ndet a
  c  "kk_sync_cell_read"
  js "_sync_cell_read"

extern prim-cell-write( c : any, x : a ) : ndet ()
  c  "kk_sync_cell_write"
  js "_sync_cell_write"

extern prim-cell-update( c : any, f : a -> a ) : ndet a
  c  "kk_sync_cell_update"
  js "_sync_cell_update"

extern prim-chan-new() : ndet any
  c  "kk_sync_chan_new"
  js "_sync_chan_new"

extern prim-chan-send( ch : any, x : a ) : ndet ()
  c  "kk_sync_chan_send"
  js "_sync_chan_send"

extern prim-chan-receive( ch : any ) : ndet a
  c  "kk_sync_chan_receive"
  js "_sync_chan_receive"

extern prim-chan-try-receive( ch : any ) : ndet maybe<a>
  c  "kk_sync_chan_try_receive"
  js "_sync_chan_try_receive"

extern prim-chan-count( ch : any ) : ndet int
  c  "kk_sync_chan_count"
  js "_sync_chan_count"
