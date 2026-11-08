/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
var _crypto = null;
if ($std_core.host()=="node") {
  _crypto = await import("crypto");
}

export function _sha_digest( data, sha256 ) {
  if (!_crypto) throw new Error("std/crypto/hash requires Node.js");
  const buf = _crypto.createHash(sha256 ? "sha256" : "sha1").update(data).digest();
  return new Uint8Array(buf.buffer, buf.byteOffset, buf.length);
}

/*---------------------------------------------------------------------------
  BLAKE2b and BLAKE2s (RFC 7693). BLAKE2b's 64-bit words are pairs of
  32-bit words (low, high).
---------------------------------------------------------------------------*/
const _blake2_sigma = [
  [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 ],
  [14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 ],
  [11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4 ],
  [ 7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8 ],
  [ 9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13 ],
  [ 2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9 ],
  [12, 5, 1,15,14,13, 4,10, 0, 7, 6, 3, 9, 2, 8,11 ],
  [13,11, 7,14,12, 1, 3, 9, 5, 0,15, 4, 8, 6, 2,10 ],
  [ 6,15,14, 9,11, 3, 0, 8,12, 2,13, 7, 1, 4,10, 5 ],
  [10, 2, 8, 4, 7, 6, 1, 5,15,11, 9,14, 3,12,13, 0 ],
  [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 ],
  [14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 ]
];

const _blake2s_iv = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19];

// (low, high) pairs
const _blake2b_iv32 = [0xF3BCC908, 0x6A09E667, 0x84CAA73B, 0xBB67AE85, 0xFE94F82B, 0x3C6EF372, 0x5F1D36F1, 0xA54FF53A,
                       0xADE682D1, 0x510E527F, 0x2B3E6C1F, 0x9B05688C, 0xFB41BD6B, 0x1F83D9AB, 0x137E2179, 0x5BE0CD19];

function _get32( b, i ) {
  return (b[i] ^ (b[i + 1] << 8) ^ (b[i + 2] << 16) ^ (b[i + 3] << 24)) >>> 0;
}

function _add64aa( v, a, b ) {
  const o0 = v[a] + v[b];
  let o1 = v[a + 1] + v[b + 1];
  if (o0 >= 0x100000000) o1++;
  v[a] = o0;
  v[a + 1] = o1;
}

function _add64ac( v, a, b0, b1 ) {
  const o0 = v[a] + b0;
  let o1 = v[a + 1] + b1;
  if (o0 >= 0x100000000) o1++;
  v[a] = o0;
  v[a + 1] = o1;
}

function _b2b_g( v, m, a, b, c, d, ix, iy ) {
  const x0 = m[ix], x1 = m[ix + 1], y0 = m[iy], y1 = m[iy + 1];
  _add64aa(v, a, b); _add64ac(v, a, x0, x1);
  let xor0 = v[d] ^ v[a], xor1 = v[d + 1] ^ v[a + 1];
  v[d] = xor1; v[d + 1] = xor0;
  _add64aa(v, c, d);
  xor0 = v[b] ^ v[c]; xor1 = v[b + 1] ^ v[c + 1];
  v[b] = (xor0 >>> 24) ^ (xor1 << 8); v[b + 1] = (xor1 >>> 24) ^ (xor0 << 8);
  _add64aa(v, a, b); _add64ac(v, a, y0, y1);
  xor0 = v[d] ^ v[a]; xor1 = v[d + 1] ^ v[a + 1];
  v[d] = (xor0 >>> 16) ^ (xor1 << 16); v[d + 1] = (xor1 >>> 16) ^ (xor0 << 16);
  _add64aa(v, c, d);
  xor0 = v[b] ^ v[c]; xor1 = v[b + 1] ^ v[c + 1];
  v[b] = (xor1 >>> 31) ^ (xor0 << 1); v[b + 1] = (xor0 >>> 31) ^ (xor1 << 1);
}

function _blake2b_compress( h, block, t, last ) {
  const v = new Uint32Array(32), m = new Uint32Array(32);
  for (let i = 0; i < 16; i++) { v[i] = h[i]; v[i + 16] = _blake2b_iv32[i]; }
  v[24] ^= t;
  v[25] ^= Math.floor(t / 0x100000000);
  if (last) { v[28] = ~v[28]; v[29] = ~v[29]; }
  for (let i = 0; i < 32; i++) m[i] = _get32(block, 4 * i);
  for (let r = 0; r < 12; r++) {
    const s = _blake2_sigma[r];
    _b2b_g(v, m, 0,  8, 16, 24, 2*s[ 0], 2*s[ 1]);
    _b2b_g(v, m, 2, 10, 18, 26, 2*s[ 2], 2*s[ 3]);
    _b2b_g(v, m, 4, 12, 20, 28, 2*s[ 4], 2*s[ 5]);
    _b2b_g(v, m, 6, 14, 22, 30, 2*s[ 6], 2*s[ 7]);
    _b2b_g(v, m, 0, 10, 20, 30, 2*s[ 8], 2*s[ 9]);
    _b2b_g(v, m, 2, 12, 22, 24, 2*s[10], 2*s[11]);
    _b2b_g(v, m, 4, 14, 16, 26, 2*s[12], 2*s[13]);
    _b2b_g(v, m, 6,  8, 18, 28, 2*s[14], 2*s[15]);
  }
  for (let i = 0; i < 16; i++) h[i] = h[i] ^ v[i] ^ v[i + 16];
}

function _rotr32( x, n ) { return ((x >>> n) | (x << (32 - n))) >>> 0; }

function _b2s_g( v, a, b, c, d, x, y ) {
  v[a] = v[a] + v[b] + x; v[d] = _rotr32(v[d] ^ v[a], 16);
  v[c] = v[c] + v[d];     v[b] = _rotr32(v[b] ^ v[c], 12);
  v[a] = v[a] + v[b] + y; v[d] = _rotr32(v[d] ^ v[a], 8);
  v[c] = v[c] + v[d];     v[b] = _rotr32(v[b] ^ v[c], 7);
}

function _blake2s_compress( h, block, t, last ) {
  const v = new Uint32Array(16), m = new Uint32Array(16);
  for (let i = 0; i < 8; i++) { v[i] = h[i]; v[i + 8] = _blake2s_iv[i]; }
  v[12] ^= t;
  v[13] ^= Math.floor(t / 0x100000000);
  if (last) v[14] = ~v[14];
  for (let i = 0; i < 16; i++) m[i] = _get32(block, 4 * i);
  for (let r = 0; r < 10; r++) {
    const s = _blake2_sigma[r];
    _b2s_g(v, 0, 4,  8, 12, m[s[ 0]], m[s[ 1]]);
    _b2s_g(v, 1, 5,  9, 13, m[s[ 2]], m[s[ 3]]);
    _b2s_g(v, 2, 6, 10, 14, m[s[ 4]], m[s[ 5]]);
    _b2s_g(v, 3, 7, 11, 15, m[s[ 6]], m[s[ 7]]);
    _b2s_g(v, 0, 5, 10, 15, m[s[ 8]], m[s[ 9]]);
    _b2s_g(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
    _b2s_g(v, 2, 7,  8, 13, m[s[12]], m[s[13]]);
    _b2s_g(v, 3, 4,  9, 14, m[s[14]], m[s[15]]);
  }
  for (let i = 0; i < 8; i++) h[i] = (h[i] ^ v[i] ^ v[i + 8]) >>> 0;
}

export function _blake2_digest( data, size, key, big ) {
  const bb = (big ? 128 : 64);
  const maxout = (big ? 64 : 32);
  const outlen = Math.min(maxout, Math.max(1, Number(size)));
  const k = key.subarray(0, Math.min(key.length, maxout));
  const h = (big ? new Uint32Array(_blake2b_iv32) : new Uint32Array(_blake2s_iv));
  h[0] ^= 0x01010000 ^ (k.length << 8) ^ outlen;
  const compress = (big ? _blake2b_compress : _blake2s_compress);
  // the input: the key padded to a block (if any), then the data
  let input = data;
  if (k.length > 0) {
    input = new Uint8Array(bb + data.length);
    input.set(k, 0);
    input.set(data, bb);
  }
  let t = 0, pos = 0;
  const block = new Uint8Array(bb);
  while (input.length - pos > bb) {
    block.set(input.subarray(pos, pos + bb));
    pos += bb;
    t += bb;
    compress(h, block, t, false);
  }
  block.fill(0);
  block.set(input.subarray(pos));
  t += input.length - pos;
  compress(h, block, t, true);
  const out = new Uint8Array(outlen);
  for (let i = 0; i < outlen; i++) out[i] = (h[i >> 2] >>> (8 * (i & 3))) & 0xFF;
  return out;
}

/*---------------------------------------------------------------------------
  BLAKE3 (a port of the reference implementation)
---------------------------------------------------------------------------*/
const _B3_CHUNK_START = 1, _B3_CHUNK_END = 2, _B3_PARENT = 4, _B3_ROOT = 8,
      _B3_KEYED_HASH = 16, _B3_DERIVE_KEY_CONTEXT = 32, _B3_DERIVE_KEY_MATERIAL = 64;
const _b3_perm = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8];

function _b3_compress( cv, block, counter, block_len, flags ) {
  const s = new Uint32Array(16);
  for (let i = 0; i < 8; i++) s[i] = cv[i];
  s[8] = _blake2s_iv[0]; s[9] = _blake2s_iv[1]; s[10] = _blake2s_iv[2]; s[11] = _blake2s_iv[3];
  s[12] = counter % 0x100000000; s[13] = Math.floor(counter / 0x100000000); s[14] = block_len; s[15] = flags;
  let m = Uint32Array.from(block);
  for (let r = 0; r < 7; r++) {
    _b2s_g(s, 0, 4,  8, 12, m[ 0], m[ 1]);
    _b2s_g(s, 1, 5,  9, 13, m[ 2], m[ 3]);
    _b2s_g(s, 2, 6, 10, 14, m[ 4], m[ 5]);
    _b2s_g(s, 3, 7, 11, 15, m[ 6], m[ 7]);
    _b2s_g(s, 0, 5, 10, 15, m[ 8], m[ 9]);
    _b2s_g(s, 1, 6, 11, 12, m[10], m[11]);
    _b2s_g(s, 2, 7,  8, 13, m[12], m[13]);
    _b2s_g(s, 3, 4,  9, 14, m[14], m[15]);
    if (r < 6) {
      const t = new Uint32Array(16);
      for (let i = 0; i < 16; i++) t[i] = m[_b3_perm[i]];
      m = t;
    }
  }
  const out = new Uint32Array(16);
  for (let i = 0; i < 8; i++) { out[i] = s[i] ^ s[i + 8]; out[i + 8] = s[i + 8] ^ cv[i]; }
  return out;
}

function _b3_words( b ) {
  const block = new Uint8Array(64);
  block.set(b.subarray(0, 64));
  const w = new Uint32Array(16);
  for (let i = 0; i < 16; i++) w[i] = _get32(block, 4 * i);
  return w;
}

function _b3_cv( o ) {
  return _b3_compress(o.cv, o.block, o.counter, o.block_len, o.flags).subarray(0, 8);
}

function _b3_chunk( key, p, chunk_counter, flags ) {
  let cv = key;
  let pos = 0, blocks = 0;
  while (p.length - pos > 64) {
    const out = _b3_compress(cv, _b3_words(p.subarray(pos, pos + 64)), chunk_counter, 64, flags | (blocks === 0 ? _B3_CHUNK_START : 0));
    cv = out.subarray(0, 8);
    pos += 64;
    blocks++;
  }
  return { cv: cv, block: _b3_words(p.subarray(pos)), counter: chunk_counter, block_len: p.length - pos,
           flags: flags | (blocks === 0 ? _B3_CHUNK_START : 0) | _B3_CHUNK_END };
}

function _b3_parent( left, right, key, flags ) {
  const block = new Uint32Array(16);
  block.set(left, 0);
  block.set(right, 8);
  return { cv: key, block: block, counter: 0, block_len: 64, flags: flags | _B3_PARENT };
}

function _b3_hash( key, flags, p, outlen ) {
  const stack = [];
  let chunk = 0, pos = 0;
  while (p.length - pos > 1024) {
    let cv = _b3_cv(_b3_chunk(key, p.subarray(pos, pos + 1024), chunk, flags));
    chunk++;
    let total = chunk;
    while (total % 2 === 0) {
      cv = _b3_cv(_b3_parent(stack.pop(), cv, key, flags));
      total = total / 2;
    }
    stack.push(cv);
    pos += 1024;
  }
  let o = _b3_chunk(key, p.subarray(pos), chunk, flags);
  while (stack.length > 0) {
    o = _b3_parent(stack.pop(), _b3_cv(o), key, flags);
  }
  const out = new Uint8Array(outlen);
  let counter = 0, written = 0;
  while (written < outlen) {
    const words = _b3_compress(o.cv, o.block, counter, o.block_len, o.flags | _B3_ROOT);
    for (let i = 0; i < 64 && written < outlen; i++) out[written++] = (words[i >> 2] >>> (8 * (i & 3))) & 0xFF;
    counter++;
  }
  return out;
}

export function _blake3_digest( data, size, key, mode ) {
  const outlen = Math.max(0, Number(size));
  const m = Number(mode);
  let kw = new Uint32Array(_blake2s_iv);
  let flags = 0;
  if (m === 1) {
    kw = _b3_words(key.subarray(0, 32)).subarray(0, 8);
    flags = _B3_KEYED_HASH;
  }
  else if (m === 2) {
    const ck = _b3_hash(kw, _B3_DERIVE_KEY_CONTEXT, key, 32);
    kw = _b3_words(ck).subarray(0, 8);
    flags = _B3_DERIVE_KEY_MATERIAL;
  }
  return _b3_hash(kw, flags, data, outlen);
}
