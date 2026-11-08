/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

// Compression with Node's `zlib`. Node offers no synchronous incremental
// (de)compression, so a (de)compressor collects its input and processes it
// all at once when the input is finished.
var _zlib = null;
if ($std_core.host()=="node") {
  _zlib = await import("zlib");
}

export function _zs_new( compress, format, level ) {
  return { compress: compress, format: Number(format), level: Number(level), chunks: [], done: false, error: "" };
}

function _zs_run( z, input ) {
  if (!_zlib) throw new Error("compression is not supported in this host");
  const lvl = (z.level >= 0 && z.level <= 9 ? z.level : -1);
  const opts = { level: lvl };
  if (z.compress) {
    switch (z.format) {
      case 0:  return _zlib.deflateRawSync(input, opts);
      case 1:  return _zlib.deflateSync(input, opts);
      default: return _zlib.gzipSync(input, opts);
    }
  }
  else {
    switch (z.format) {
      case 0:  return _zlib.inflateRawSync(input);
      case 1:  return _zlib.inflateSync(input);
      case 2:  return _zlib.gunzipSync(input);
      default: return _zlib.unzipSync(input);
    }
  }
}

export function _zs_push( z, input, finish ) {
  const out = _zs_push_bytes(z, input, finish);
  return $std_core_types.Tuple2(out, z.error);
}

function _zs_push_bytes( z, input, finish ) {
  if (z.error !== "" || z.done) return new Uint8Array(0);
  if (input.length > 0) z.chunks.push(input);
  if (!finish) return new Uint8Array(0);
  z.done = true;
  const all = (z.chunks.length === 1 ? z.chunks[0] : Buffer.concat(z.chunks));
  z.chunks = [];
  try {
    const out = _zs_run(z, all);
    return new Uint8Array(out.buffer, out.byteOffset, out.length);
  }
  catch(exn) {
    let msg = (exn.message || String(exn));
    if (exn.code === "Z_BUF_ERROR" || msg === "unexpected end of file") msg = "unexpected end of the compressed data";
    z.error = (z.compress ? "compress: " : "decompress: ") + msg;
    return new Uint8Array(0);
  }
}

var _crc_table = null;
export function _zs_crc32( b, init ) {
  if (_zlib && _zlib.crc32) return _zlib.crc32(b, Number(init));
  if (!_crc_table) {
    _crc_table = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = (c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1);
      _crc_table[n] = c >>> 0;
    }
  }
  let crc = (Number(init) ^ 0xFFFFFFFF) >>> 0;
  for (let i = 0; i < b.length; i++) crc = (_crc_table[(crc ^ b[i]) & 0xFF] ^ (crc >>> 8)) >>> 0;
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

export function _zs_adler32( b, init ) {
  let a = Number(init) & 0xFFFF;
  let s = (Number(init) >>> 16) & 0xFFFF;
  for (let i = 0; i < b.length; i++) {
    a = (a + b[i]) % 65521;
    s = (s + a) % 65521;
  }
  return ((s << 16) | a) >>> 0;
}
