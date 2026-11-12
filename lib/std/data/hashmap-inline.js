/*---------------------------------------------------------------------------
  Copying updates of the child vectors of std/data/hashmap nodes.
---------------------------------------------------------------------------*/

export function _hamt_replace(v, i, x) {
  const w = v.slice();
  w[i] = x;
  return w;
}

export function _hamt_insert(v, i, x) {
  const w = new Array(v.length + 1);
  for (let j = 0; j < i; j++) w[j] = v[j];
  w[i] = x;
  for (let j = i; j < v.length; j++) w[j+1] = v[j];
  return w;
}

export function _hamt_remove(v, i) {
  const w = new Array(v.length - 1);
  for (let j = 0; j < i; j++) w[j] = v[j];
  for (let j = i + 1; j < v.length; j++) w[j-1] = v[j];
  return w;
}
