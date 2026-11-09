/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

// Brotli with Node's `zlib`. Node offers no synchronous incremental
// (de)compression, so a (de)compressor collects its input and processes it
// all at once when the input is finished.
var _zlib = null;
if ($std_core.host()=="node") {
  _zlib = await import("zlib");
}

export function _br_new( compress, quality, window ) {
  return { compress: compress, quality: Number(quality), window: Number(window), chunks: [], done: false, error: "" };
}

function _br_run( z, input ) {
  if (!_zlib || !_zlib.brotliCompressSync) throw new Error("brotli is not supported in this host");
  const C = _zlib.constants;
  if (z.compress) {
    const params = {};
    if (z.quality >= C.BROTLI_MIN_QUALITY && z.quality <= C.BROTLI_MAX_QUALITY) params[C.BROTLI_PARAM_QUALITY] = z.quality;
    if (z.window >= C.BROTLI_MIN_WINDOW_BITS && z.window <= C.BROTLI_MAX_WINDOW_BITS) params[C.BROTLI_PARAM_LGWIN] = z.window;
    params[C.BROTLI_PARAM_SIZE_HINT] = input.length;
    return _zlib.brotliCompressSync(input, { params: params });
  }
  else {
    return _zlib.brotliDecompressSync(input);
  }
}

export function _br_push( z, input, finish ) {
  return $std_core_types.Tuple2(_br_push_bytes(z, input, finish), z.error);
}

function _br_push_bytes( z, input, finish ) {
  if (z.error !== "" || z.done) return new Uint8Array(0);
  if (input.length > 0) z.chunks.push(input);
  if (!finish) return new Uint8Array(0);
  z.done = true;
  const all = (z.chunks.length === 1 ? z.chunks[0] : Buffer.concat(z.chunks));
  z.chunks = [];
  try {
    const out = _br_run(z, all);
    return new Uint8Array(out.buffer, out.byteOffset, out.length);
  }
  catch(exn) {
    let msg = (exn.message || String(exn));
    if (exn.code === "ERR__ERROR_FORMAT_PADDING_1" || msg === "unexpected end of file") msg = "unexpected end of the compressed data";
    z.error = (z.compress ? "compress: " : "decompress: ") + msg;
    return new Uint8Array(0);
  }
}
