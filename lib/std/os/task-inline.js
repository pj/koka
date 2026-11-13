/*---------------------------------------------------------------------------
  std/os/task on JavaScript: there are no threads, so a task runs when it is
  created, and `await` returns its result. (Tasks are pure, so only the
  timing differs from the C backend.)
---------------------------------------------------------------------------*/

export function _task_schedule(work) {
  return { value: work() };
}

export function _task_await(p) {
  return p.value;
}

export function _lvar_alloc(init) {
  return { value: init };
}

export function _lvar_put(lv, x, combine) {
  lv.value = combine(lv.value, x);
  return $std_core_types.Unit;
}

export function _lvar_get(lv, bot, is_gte) {
  if (is_gte(lv.value, bot) !== 0) return lv.value;
  throw new Error("std/os/task: deadlock (waiting for an lvar, and there are no threads on this backend)");
}
