/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

// Zstandard with Node's `zlib`. Node offers no synchronous incremental
// (de)compression, so a (de)compressor collects its input and processes it
// all at once when the input is finished.
var _zlib = null;
if ($std_core.host()=="node") {
  _zlib = await import("zlib");
}

export function _zstd_new( compress, level ) {
  return { compress: compress, level: Number(level), chunks: [], done: false, error: "" };
}

function _zstd_run( z, input ) {
  if (!_zlib || !_zlib.zstdCompressSync) throw new Error("zstd is not supported in this host (it needs Node 22.15 or later)");
  const C = _zlib.constants;
  if (z.compress) {
    const params = {};
    params[C.ZSTD_c_checksumFlag] = 1;
    if (z.level !== 0 && z.level >= -131072 && z.level <= 22) params[C.ZSTD_c_compressionLevel] = z.level;
    return _zlib.zstdCompressSync(input, { params: params });
  }
  else {
    // Node decompresses only the first frame: split the frames, and skip skippable ones
    const parts = [];
    for (const [start, end] of _zstd_frames(input)) {
      parts.push(_zlib.zstdDecompressSync(input.subarray(start, end)));
    }
    return (parts.length === 1 ? parts[0] : Buffer.concat(parts));
  }
}

// The [start,end) ranges of the (non-skippable) frames in `b` (RFC 8878).
// Data that is cut off ends the last range at the end of `b`, so that
// decompressing it reports the error.
function _zstd_frames( b ) {
  const frames = [];
  let i = 0;
  const u32 = (k) => (b[k] | (b[k+1] << 8) | (b[k+2] << 16) | (b[k+3] << 24)) >>> 0;
  while (i < b.length) {
    if (i + 8 <= b.length && (u32(i) & 0xFFFFFFF0) === 0x184D2A50) {  // skippable frame
      i += 8 + u32(i+4);
      continue;
    }
    const start = i;
    if (i + 5 > b.length || u32(i) !== 0xFD2FB528) { frames.push([start, b.length]); break; }
    const fhd = b[i+4];
    const single = (fhd >> 5) & 1;
    const fcsSize = [single ? 1 : 0, 2, 4, 8][fhd >> 6];
    const didSize = [0, 1, 2, 4][fhd & 3];
    i += 5 + (single ? 0 : 1) + didSize + fcsSize;
    let last = false;
    while (!last && i + 3 <= b.length) {
      const hdr = b[i] | (b[i+1] << 8) | (b[i+2] << 16);
      last = (hdr & 1) === 1;
      const type = (hdr >> 1) & 3;
      const size = hdr >>> 3;
      i += 3 + (type === 1 ? 1 : size);
    }
    if (last && ((fhd >> 2) & 1)) i += 4;  // content checksum
    if (!last || i > b.length) { frames.push([start, b.length]); break; }
    frames.push([start, i]);
  }
  if (frames.length === 0) frames.push([0, b.length]);  // (empty or only skippable frames)
  return frames;
}

export function _zstd_push( z, input, finish ) {
  return $std_core_types.Tuple2(_zstd_push_bytes(z, input, finish), z.error);
}

function _zstd_push_bytes( z, input, finish ) {
  if (z.error !== "" || z.done) return new Uint8Array(0);
  if (input.length > 0) z.chunks.push(input);
  if (!finish) return new Uint8Array(0);
  z.done = true;
  const all = (z.chunks.length === 1 ? z.chunks[0] : Buffer.concat(z.chunks));
  z.chunks = [];
  try {
    const out = _zstd_run(z, all);
    return new Uint8Array(out.buffer, out.byteOffset, out.length);
  }
  catch(exn) {
    let msg = (exn.message || String(exn));
    if (msg === "unexpected end of file") msg = "unexpected end of the compressed data";
    z.error = (z.compress ? "compress: " : "decompress: ") + msg;
    return new Uint8Array(0);
  }
}
