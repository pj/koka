/*---------------------------------------------------------------------------
  Hashing primitives (MurmurHash3, 32-bit) for std/data/hash.
  These produce the same results as hash-inline.c.
---------------------------------------------------------------------------*/

function _hash_scramble32(k) {
  k = Math.imul(k, 0xcc9e2d51);
  k = (k << 15) | (k >>> 17);
  return Math.imul(k, 0x1b873593);
}

export function _hash_mix32(h, k) {
  h ^= _hash_scramble32(k);
  h = (h << 13) | (h >>> 19);
  return (Math.imul(h, 5) + 0xe6546b64) | 0;
}

export function _hash_fmix32(h) {
  h ^= h >>> 16;
  h = Math.imul(h, 0x85ebca6b);
  h ^= h >>> 13;
  h = Math.imul(h, 0xc2b2ae35);
  h ^= h >>> 16;
  return h | 0;
}

// MurmurHash3_x86_32 over the UTF-8 bytes of a string
export function _hash_string32(s, seed) {
  let h = seed | 0;
  let k = 0;
  let n = 0;
  const push = (b) => {
    k |= b << ((n & 3) * 8);
    n++;
    if ((n & 3) === 0) { h = _hash_mix32(h, k); k = 0; }
  };
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
      const lo = s.charCodeAt(i + 1);
      if (lo >= 0xDC00 && lo <= 0xDFFF) { c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00); i++; }
    }
    if (c < 0x80) push(c);
    else if (c < 0x800) { push(0xC0 | (c >> 6)); push(0x80 | (c & 63)); }
    else if (c < 0x10000) { push(0xE0 | (c >> 12)); push(0x80 | ((c >> 6) & 63)); push(0x80 | (c & 63)); }
    else { push(0xF0 | (c >> 18)); push(0x80 | ((c >> 12) & 63)); push(0x80 | ((c >> 6) & 63)); push(0x80 | (c & 63)); }
  }
  if ((n & 3) !== 0) h ^= _hash_scramble32(k);
  h ^= n;
  return _hash_fmix32(h);
}
