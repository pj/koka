/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// JavaScript has no threads here: tasks run when they are spawned, so these
// primitives are plain objects.
export function _sync_atomic_new( i ) { return { v: i }; }
export function _sync_atomic_load( a ) { return a.v; }
export function _sync_atomic_store( a, i ) { a.v = i; return $std_core_types.Unit; }
export function _sync_atomic_fetch_add( a, i ) { const old = a.v; a.v = $std_core_types._int_add(old, i); return old; }
export function _sync_atomic_exchange( a, i ) { const old = a.v; a.v = i; return old; }
export function _sync_atomic_cas( a, e, d ) {
  if ($std_core_types._int_eq(a.v, e)) { a.v = d; return true; }
  return false;
}

export function _sync_mutex_new() { return { locked: false }; }
export function _sync_mutex_lock( m ) {
  if (m.locked) throw new Error("std/os/sync: deadlock (the mutex is already locked, and there are no threads on this backend)");
  m.locked = true;
  return $std_core_types.Unit;
}
export function _sync_mutex_unlock( m ) { m.locked = false; return $std_core_types.Unit; }

export function _sync_cell_new( x ) { return { value: x }; }
export function _sync_cell_read( c ) { return c.value; }
export function _sync_cell_write( c, x ) { c.value = x; return $std_core_types.Unit; }
export function _sync_cell_update( c, f ) { c.value = f(c.value); return c.value; }

export function _sync_chan_new( limit ) { return { items: [], limit: Number(limit) }; }
function _sync_chan_full( ch ) { return (ch.limit > 0 && ch.items.length >= ch.limit); }
export function _sync_chan_send( ch, x ) {
  if (_sync_chan_full(ch)) throw new Error("std/os/sync: deadlock (sending to a full channel, and there are no threads on this backend)");
  ch.items.push(x);
  return $std_core_types.Unit;
}
export function _sync_chan_try_send( ch, x ) {
  if (_sync_chan_full(ch)) return false;
  ch.items.push(x);
  return true;
}
export function _sync_chan_receive( ch ) {
  if (ch.items.length === 0) throw new Error("std/os/sync: deadlock (receiving from an empty channel, and there are no threads on this backend)");
  return ch.items.shift();
}
export function _sync_chan_try_receive( ch ) {
  return (ch.items.length === 0 ? $std_core_types.Nothing : $std_core_types.Just(ch.items.shift()));
}
export function _sync_chan_count( ch ) { return ch.items.length; }

export function _sync_spawn( work ) { return { result: work() }; }
export function _sync_join( p ) { return p.result; }
