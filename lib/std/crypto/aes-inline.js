/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
var _aes_crypto = null;
if ($std_core.host()=="node") {
  _aes_crypto = await import("crypto");
}

function _aes_ecb( key, data ) {
  const c = _aes_crypto.createCipheriv("aes-" + (key.length * 8) + "-ecb", key, null);
  c.setAutoPadding(false);
  const out = Buffer.concat([c.update(data), c.final()]);
  return new Uint8Array(out.buffer, out.byteOffset, out.length);
}

function _aes_key_ok( key ) { return key.length === 16 || key.length === 24 || key.length === 32; }

export function _aes_ecb_encrypt( key, data ) {
  if (!_aes_key_ok(key) || data.length === 0 || data.length % 16 !== 0) return new Uint8Array(0);
  return _aes_ecb(key, data);
}

export function _aes_ctr( key, iv, data, little ) {
  if (!_aes_key_ok(key) || iv.length !== 16 || data.length === 0) return new Uint8Array(0);
  const nblocks = Math.ceil(data.length / 16);
  const counters = new Uint8Array(nblocks * 16);
  const ctr = Uint8Array.from(iv);
  for (let b = 0; b < nblocks; b++) {
    counters.set(ctr, b * 16);
    if (little) { for (let j = 0; j < 16; j++) { ctr[j] = (ctr[j] + 1) & 0xFF; if (ctr[j] !== 0) break; } }
    else        { for (let j = 15; j >= 0; j--) { ctr[j] = (ctr[j] + 1) & 0xFF; if (ctr[j] !== 0) break; } }
  }
  const ks = _aes_ecb(key, counters);
  const out = new Uint8Array(data.length);
  for (let i = 0; i < data.length; i++) out[i] = data[i] ^ ks[i];
  return out;
}

export function _bytes_xor( a, b ) {
  const n = Math.min(a.length, b.length);
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) out[i] = a[i] ^ b[i];
  return out;
}
