/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// Traditional PKWARE zip encryption ("ZipCrypto").
var _zipcrypto_table = null;

function _zipcrypto_crc( crc, b ) {
  if (!_zipcrypto_table) {
    _zipcrypto_table = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = (c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1);
      _zipcrypto_table[n] = c >>> 0;
    }
  }
  return ((crc >>> 8) ^ _zipcrypto_table[(crc ^ b) & 0xFF]) >>> 0;
}

export function _zipcrypto( password, data, decrypt ) {
  const k = new Uint32Array([0x12345678, 0x23456789, 0x34567890]);
  const update = (c) => {
    k[0] = _zipcrypto_crc(k[0], c);
    k[1] = (Math.imul((k[1] + (k[0] & 0xFF)) >>> 0, 134775813) + 1) >>> 0;
    k[2] = _zipcrypto_crc(k[2], k[1] >>> 24);
  };
  for (let i = 0; i < password.length; i++) update(password[i]);
  const out = new Uint8Array(data.length);
  for (let i = 0; i < data.length; i++) {
    const t = (k[2] | 2) & 0xFFFF;
    const s = ((Math.imul(t, t ^ 1)) >>> 8) & 0xFF;
    const c = data[i] ^ s;
    out[i] = c;
    update(decrypt ? c : data[i]);
  }
  return out;
}
