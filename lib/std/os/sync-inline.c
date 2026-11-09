/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// Thread-safe primitives: boxed C pointers. Values that are stored in them
// are marked as thread shared (so that their reference counts are atomic).
#include <stdatomic.h>
#if defined(_WIN32)
// Windows: slim reader/writer locks and condition variables
#include <windows.h>
typedef SRWLOCK            kk_sync_lock_t;
typedef CONDITION_VARIABLE kk_sync_cond_t;
#define kk_sync_mutex_init(m)     InitializeSRWLock(m)
#define kk_sync_mutex_destroy(m)  ((void)(m))
#define kk_sync_mutex_lock_(m)    AcquireSRWLockExclusive(m)
#define kk_sync_mutex_unlock_(m)  ReleaseSRWLockExclusive(m)
#define kk_sync_cond_init(c)      InitializeConditionVariable(c)
#define kk_sync_cond_destroy(c)   ((void)(c))
#define kk_sync_cond_wait(c,m)    SleepConditionVariableSRW(c, m, INFINITE, 0)
#define kk_sync_cond_signal(c)    WakeConditionVariable(c)
#define kk_sync_cond_broadcast(c) WakeAllConditionVariable(c)
// returns false on a timeout
static bool kk_sync_cond_timedwait( kk_sync_cond_t* c, kk_sync_lock_t* m, int64_t ms ) {
  return SleepConditionVariableSRW(c, m, (ms < 0 ? 0 : (ms >= INFINITE ? INFINITE - 1 : (DWORD)ms)), 0);
}
#else
#include <pthread.h>
typedef pthread_mutex_t    kk_sync_lock_t;
typedef pthread_cond_t     kk_sync_cond_t;
#define kk_sync_mutex_init(m)     pthread_mutex_init(m, NULL)
#define kk_sync_mutex_destroy(m)  pthread_mutex_destroy(m)
#define kk_sync_mutex_lock_(m)    pthread_mutex_lock(m)
#define kk_sync_mutex_unlock_(m)  pthread_mutex_unlock(m)
#define kk_sync_cond_init(c)      pthread_cond_init(c, NULL)
#define kk_sync_cond_destroy(c)   pthread_cond_destroy(c)
#define kk_sync_cond_wait(c,m)    pthread_cond_wait(c, m)
#define kk_sync_cond_signal(c)    pthread_cond_signal(c)
#define kk_sync_cond_broadcast(c) pthread_cond_broadcast(c)
#include <time.h>
#include <errno.h>
// returns false on a timeout
static bool kk_sync_cond_timedwait( kk_sync_cond_t* c, kk_sync_lock_t* m, int64_t ms ) {
  if (ms < 0) ms = 0;
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  ts.tv_sec  += (time_t)(ms / 1000);
  ts.tv_nsec += (long)(ms % 1000) * 1000000L;
  if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
  return (pthread_cond_timedwait(c, m, &ts) != ETIMEDOUT);
}
#endif
#include <string.h>

// --- atomic integers (64-bit)

typedef struct kk_sync_atomic_s { _Atomic(int64_t) v; } kk_sync_atomic_t;

static void kk_sync_free( void* p, kk_block_t* block, kk_context_t* ctx ) {
  kk_unused(block);
  kk_free(p,ctx);
}

static kk_box_t kk_sync_atomic_new( kk_integer_t i, kk_context_t* ctx ) {
  kk_sync_atomic_t* a = (kk_sync_atomic_t*)kk_malloc(sizeof(kk_sync_atomic_t),ctx);
  atomic_init(&a->v, kk_integer_clamp64(i,ctx));
  kk_box_t b = kk_cptr_raw_box(&kk_sync_free, a, ctx);
  kk_box_mark_shared(b,ctx);
  return b;
}

static _Atomic(int64_t)* kk_sync_atomic_of( kk_box_t b, kk_context_t* ctx ) {
  return &((kk_sync_atomic_t*)kk_cptr_raw_unbox_borrowed(b,ctx))->v;
}

static kk_integer_t kk_sync_atomic_load( kk_box_t b, kk_context_t* ctx ) {
  const int64_t v = atomic_load(kk_sync_atomic_of(b,ctx));
  kk_box_drop(b,ctx);
  return kk_integer_from_int64(v,ctx);
}

static kk_unit_t kk_sync_atomic_store( kk_box_t b, kk_integer_t i, kk_context_t* ctx ) {
  atomic_store(kk_sync_atomic_of(b,ctx), kk_integer_clamp64(i,ctx));
  kk_box_drop(b,ctx);
  return kk_Unit;
}

// Returns the old value.
static kk_integer_t kk_sync_atomic_fetch_add( kk_box_t b, kk_integer_t i, kk_context_t* ctx ) {
  const int64_t v = atomic_fetch_add(kk_sync_atomic_of(b,ctx), kk_integer_clamp64(i,ctx));
  kk_box_drop(b,ctx);
  return kk_integer_from_int64(v,ctx);
}

static kk_integer_t kk_sync_atomic_exchange( kk_box_t b, kk_integer_t i, kk_context_t* ctx ) {
  const int64_t v = atomic_exchange(kk_sync_atomic_of(b,ctx), kk_integer_clamp64(i,ctx));
  kk_box_drop(b,ctx);
  return kk_integer_from_int64(v,ctx);
}

static bool kk_sync_atomic_cas( kk_box_t b, kk_integer_t expected, kk_integer_t desired, kk_context_t* ctx ) {
  int64_t e = kk_integer_clamp64(expected,ctx);
  const bool ok = atomic_compare_exchange_strong(kk_sync_atomic_of(b,ctx), &e, kk_integer_clamp64(desired,ctx));
  kk_box_drop(b,ctx);
  return ok;
}

// --- mutexes

typedef struct kk_sync_mutex_s { kk_sync_lock_t m; } kk_sync_mutex_t;

static void kk_sync_mutex_free( void* p, kk_block_t* block, kk_context_t* ctx ) {
  kk_unused(block);
  kk_sync_mutex_destroy(&((kk_sync_mutex_t*)p)->m);
  kk_free(p,ctx);
}

static kk_box_t kk_sync_mutex_new( kk_context_t* ctx ) {
  kk_sync_mutex_t* m = (kk_sync_mutex_t*)kk_malloc(sizeof(kk_sync_mutex_t),ctx);
  kk_sync_mutex_init(&m->m);
  kk_box_t b = kk_cptr_raw_box(&kk_sync_mutex_free, m, ctx);
  kk_box_mark_shared(b,ctx);
  return b;
}

static kk_unit_t kk_sync_mutex_lock( kk_box_t b, kk_context_t* ctx ) {
  kk_sync_mutex_lock_(&((kk_sync_mutex_t*)kk_cptr_raw_unbox_borrowed(b,ctx))->m);
  kk_box_drop(b,ctx);
  return kk_Unit;
}

static kk_unit_t kk_sync_mutex_unlock( kk_box_t b, kk_context_t* ctx ) {
  kk_sync_mutex_unlock_(&((kk_sync_mutex_t*)kk_cptr_raw_unbox_borrowed(b,ctx))->m);
  kk_box_drop(b,ctx);
  return kk_Unit;
}

static kk_sync_lock_t* kk_sync_mutex_of( kk_box_t b, kk_context_t* ctx ) {
  return &((kk_sync_mutex_t*)kk_cptr_raw_unbox_borrowed(b,ctx))->m;
}

// --- condition variables (used with a mutex)

typedef struct kk_sync_condition_s { kk_sync_cond_t c; } kk_sync_condition_t;

static void kk_sync_condition_free( void* p, kk_block_t* block, kk_context_t* ctx ) {
  kk_unused(block);
  kk_sync_cond_destroy(&((kk_sync_condition_t*)p)->c);
  kk_free(p,ctx);
}

static kk_box_t kk_sync_condition_new( kk_context_t* ctx ) {
  kk_sync_condition_t* c = (kk_sync_condition_t*)kk_malloc(sizeof(kk_sync_condition_t),ctx);
  kk_sync_cond_init(&c->c);
  kk_box_t b = kk_cptr_raw_box(&kk_sync_condition_free, c, ctx);
  kk_box_mark_shared(b,ctx);
  return b;
}

static kk_sync_cond_t* kk_sync_condition_of( kk_box_t b, kk_context_t* ctx ) {
  return &((kk_sync_condition_t*)kk_cptr_raw_unbox_borrowed(b,ctx))->c;
}

// the mutex `m` is held by the caller
static kk_unit_t kk_sync_condition_wait( kk_box_t c, kk_box_t m, kk_context_t* ctx ) {
  kk_sync_cond_wait(kk_sync_condition_of(c,ctx), kk_sync_mutex_of(m,ctx));
  kk_box_drop(c,ctx);
  kk_box_drop(m,ctx);
  return kk_Unit;
}

// returns false on a timeout
static bool kk_sync_condition_wait_for( kk_box_t c, kk_box_t m, int64_t ms, kk_context_t* ctx ) {
  const bool woken = kk_sync_cond_timedwait(kk_sync_condition_of(c,ctx), kk_sync_mutex_of(m,ctx), ms);
  kk_box_drop(c,ctx);
  kk_box_drop(m,ctx);
  return woken;
}

static kk_unit_t kk_sync_condition_notify( kk_box_t c, bool all, kk_context_t* ctx ) {
  if (all) { kk_sync_cond_broadcast(kk_sync_condition_of(c,ctx)); }
      else { kk_sync_cond_signal(kk_sync_condition_of(c,ctx)); }
  kk_box_drop(c,ctx);
  return kk_Unit;
}

// --- shared cells: a value guarded by a mutex

typedef struct kk_sync_cell_s { kk_sync_lock_t m; kk_box_t value; } kk_sync_cell_t;

static void kk_sync_cell_free( void* p, kk_block_t* block, kk_context_t* ctx ) {
  kk_unused(block);
  kk_sync_cell_t* c = (kk_sync_cell_t*)p;
  kk_sync_mutex_destroy(&c->m);
  kk_box_drop(c->value,ctx);
  kk_free(c,ctx);
}

static kk_box_t kk_sync_cell_new( kk_box_t x, kk_context_t* ctx ) {
  kk_sync_cell_t* c = (kk_sync_cell_t*)kk_malloc(sizeof(kk_sync_cell_t),ctx);
  kk_sync_mutex_init(&c->m);
  kk_box_mark_shared(x,ctx);
  c->value = x;
  kk_box_t b = kk_cptr_raw_box(&kk_sync_cell_free, c, ctx);
  kk_box_mark_shared(b,ctx);
  return b;
}

static kk_sync_cell_t* kk_sync_cell_of( kk_box_t b, kk_context_t* ctx ) {
  return (kk_sync_cell_t*)kk_cptr_raw_unbox_borrowed(b,ctx);
}

static kk_box_t kk_sync_cell_read( kk_box_t b, kk_context_t* ctx ) {
  kk_sync_cell_t* c = kk_sync_cell_of(b,ctx);
  kk_sync_mutex_lock_(&c->m);
  kk_box_t x = kk_box_dup(c->value,ctx);
  kk_sync_mutex_unlock_(&c->m);
  kk_box_drop(b,ctx);
  return x;
}

static kk_unit_t kk_sync_cell_write( kk_box_t b, kk_box_t x, kk_context_t* ctx ) {
  kk_sync_cell_t* c = kk_sync_cell_of(b,ctx);
  kk_box_mark_shared(x,ctx);
  kk_sync_mutex_lock_(&c->m);
  kk_box_t old = c->value;
  c->value = x;
  kk_sync_mutex_unlock_(&c->m);
  kk_box_drop(old,ctx);
  kk_box_drop(b,ctx);
  return kk_Unit;
}

// Replace the value with `f(value)` under the lock; returns the new value.
static kk_box_t kk_sync_cell_update( kk_box_t b, kk_function_t f, kk_context_t* ctx ) {
  kk_sync_cell_t* c = kk_sync_cell_of(b,ctx);
  kk_sync_mutex_lock_(&c->m);
  kk_box_t x = kk_function_call(kk_box_t, (kk_function_t, kk_box_t, kk_context_t*), f, (f, c->value, ctx), ctx);
  kk_box_mark_shared(x,ctx);
  c->value = kk_box_dup(x,ctx);
  kk_sync_mutex_unlock_(&c->m);
  kk_box_drop(b,ctx);
  return x;
}

// --- channels: a queue with a condition variable

typedef struct kk_sync_chan_s {
  kk_sync_lock_t  m;
  kk_sync_cond_t  available;
  kk_sync_cond_t  space;    // signalled when an item is taken (for bounded channels)
  kk_ssize_t      limit;    // the capacity, or 0 if unbounded
  kk_box_t*       items;
  kk_ssize_t      head;     // index of the first item
  kk_ssize_t      count;
  kk_ssize_t      cap;
} kk_sync_chan_t;

static void kk_sync_chan_free( void* p, kk_block_t* block, kk_context_t* ctx ) {
  kk_unused(block);
  kk_sync_chan_t* ch = (kk_sync_chan_t*)p;
  for (kk_ssize_t i = 0; i < ch->count; i++) kk_box_drop(ch->items[(ch->head + i) % ch->cap],ctx);
  if (ch->items != NULL) kk_free(ch->items,ctx);
  kk_sync_mutex_destroy(&ch->m);
  kk_sync_cond_destroy(&ch->available);
  kk_sync_cond_destroy(&ch->space);
  kk_free(ch,ctx);
}

static kk_box_t kk_sync_chan_new( kk_integer_t limit, kk_context_t* ctx ) {
  kk_sync_chan_t* ch = (kk_sync_chan_t*)kk_malloc(sizeof(kk_sync_chan_t),ctx);
  memset(ch, 0, sizeof(kk_sync_chan_t));
  const kk_ssize_t lim = kk_integer_clamp_ssize_t(limit,ctx);
  ch->limit = (lim > 0 ? lim : 0);
  kk_sync_mutex_init(&ch->m);
  kk_sync_cond_init(&ch->available);
  kk_sync_cond_init(&ch->space);
  kk_box_t b = kk_cptr_raw_box(&kk_sync_chan_free, ch, ctx);
  kk_box_mark_shared(b,ctx);
  return b;
}

static kk_sync_chan_t* kk_sync_chan_of( kk_box_t b, kk_context_t* ctx ) {
  return (kk_sync_chan_t*)kk_cptr_raw_unbox_borrowed(b,ctx);
}

// Add an item (the lock is held, and there is room).
static void kk_sync_chan_push( kk_sync_chan_t* ch, kk_box_t x, kk_context_t* ctx ) {
  if (ch->count == ch->cap) {
    const kk_ssize_t newcap = (ch->cap == 0 ? 16 : 2 * ch->cap);
    kk_box_t* items = (kk_box_t*)kk_malloc(newcap * (kk_ssize_t)sizeof(kk_box_t), ctx);
    for (kk_ssize_t i = 0; i < ch->count; i++) items[i] = ch->items[(ch->head + i) % ch->cap];
    if (ch->items != NULL) kk_free(ch->items,ctx);
    ch->items = items;
    ch->head = 0;
    ch->cap = newcap;
  }
  ch->items[(ch->head + ch->count) % ch->cap] = x;
  ch->count++;
  kk_sync_cond_signal(&ch->available);
}

static bool kk_sync_chan_full( kk_sync_chan_t* ch ) {
  return (ch->limit > 0 && ch->count >= ch->limit);
}

// Add an item, waiting while a bounded channel is full.
static kk_unit_t kk_sync_chan_send( kk_box_t b, kk_box_t x, kk_context_t* ctx ) {
  kk_sync_chan_t* ch = kk_sync_chan_of(b,ctx);
  kk_box_mark_shared(x,ctx);
  kk_sync_mutex_lock_(&ch->m);
  while (kk_sync_chan_full(ch)) kk_sync_cond_wait(&ch->space, &ch->m);
  kk_sync_chan_push(ch, x, ctx);
  kk_sync_mutex_unlock_(&ch->m);
  kk_box_drop(b,ctx);
  return kk_Unit;
}

// Add an item if there is room; returns whether it was added.
static bool kk_sync_chan_try_send( kk_box_t b, kk_box_t x, kk_context_t* ctx ) {
  kk_sync_chan_t* ch = kk_sync_chan_of(b,ctx);
  kk_sync_mutex_lock_(&ch->m);
  const bool ok = !kk_sync_chan_full(ch);
  if (ok) {
    kk_box_mark_shared(x,ctx);
    kk_sync_chan_push(ch, x, ctx);
  }
  kk_sync_mutex_unlock_(&ch->m);
  if (!ok) kk_box_drop(x,ctx);
  kk_box_drop(b,ctx);
  return ok;
}

static kk_box_t kk_sync_chan_take( kk_sync_chan_t* ch ) {
  kk_box_t x = ch->items[ch->head];
  ch->head = (ch->head + 1) % ch->cap;
  ch->count--;
  kk_sync_cond_signal(&ch->space);
  return x;
}

static kk_box_t kk_sync_chan_receive( kk_box_t b, kk_context_t* ctx ) {
  kk_sync_chan_t* ch = kk_sync_chan_of(b,ctx);
  kk_sync_mutex_lock_(&ch->m);
  while (ch->count == 0) kk_sync_cond_wait(&ch->available, &ch->m);
  kk_box_t x = kk_sync_chan_take(ch);
  kk_sync_mutex_unlock_(&ch->m);
  kk_box_drop(b,ctx);
  return x;
}

static kk_std_core_types__maybe kk_sync_chan_try_receive( kk_box_t b, kk_context_t* ctx ) {
  kk_sync_chan_t* ch = kk_sync_chan_of(b,ctx);
  kk_sync_mutex_lock_(&ch->m);
  const bool any = (ch->count > 0);
  kk_box_t x = (any ? kk_sync_chan_take(ch) : kk_box_null());
  kk_sync_mutex_unlock_(&ch->m);
  kk_box_drop(b,ctx);
  return (any ? kk_std_core_types__new_Just(x,ctx) : kk_std_core_types__new_Nothing(ctx));
}

static kk_integer_t kk_sync_chan_count( kk_box_t b, kk_context_t* ctx ) {
  kk_sync_chan_t* ch = kk_sync_chan_of(b,ctx);
  kk_sync_mutex_lock_(&ch->m);
  const kk_ssize_t n = ch->count;
  kk_sync_mutex_unlock_(&ch->m);
  kk_box_drop(b,ctx);
  return kk_integer_from_ssize_t(n,ctx);
}
