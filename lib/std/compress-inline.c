/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/*---------------------------------------------------------------------------
  Compression with zlib. A (de)compressor is a boxed C pointer to a
  `kk_zs_t`; its finalizer releases the zlib state.
---------------------------------------------------------------------------*/
#include <stdio.h>
#include <string.h>
#include <zlib.h>

typedef struct kk_zs_s {
  z_stream strm;
  bool     compress;
  bool     gzip;         // decompressing gzip: continue with the next member after the end of one
  bool     done;         // the end of the (last) compressed stream was reached
  char     error[128];   // the last error ("" if none)
} kk_zs_t;

static void kk_zs_free( void* p, kk_block_t* block, kk_context_t* ctx ) {
  kk_unused(block);
  kk_zs_t* z = (kk_zs_t*)p;
  if (z->compress) deflateEnd(&z->strm); else inflateEnd(&z->strm);
  kk_free(z,ctx);
}

// format 0: raw deflate, 1: zlib, 2: gzip, 3: gzip or zlib (detected; decompression only)
static int kk_zs_window_bits( int format ) {
  switch (format) {
    case 0:  return -15;
    case 1:  return 15;
    case 2:  return 31;
    default: return 47;
  }
}

static kk_box_t kk_zs_new( bool compress, kk_integer_t format, kk_integer_t level, kk_context_t* ctx ) {
  const int fmt = kk_integer_clamp32(format,ctx);
  int lvl = kk_integer_clamp32(level,ctx);
  if (lvl < 0 || lvl > 9) lvl = Z_DEFAULT_COMPRESSION;
  kk_zs_t* z = (kk_zs_t*)kk_malloc(sizeof(kk_zs_t),ctx);
  memset(z, 0, sizeof(kk_zs_t));
  z->compress = compress;
  z->gzip = (fmt >= 2);
  int ret;
  if (compress) {
    ret = deflateInit2(&z->strm, lvl, Z_DEFLATED, kk_zs_window_bits(fmt == 3 ? 2 : fmt), 8, Z_DEFAULT_STRATEGY);
  }
  else {
    ret = inflateInit2(&z->strm, kk_zs_window_bits(fmt));
  }
  if (ret != Z_OK) {
    snprintf(z->error, sizeof(z->error), "unable to initialize zlib (%d)", ret);
    // keep the error; the state is not usable (and must not be ended)
    z->done = true;
    z->compress = true;
    deflateInit(&z->strm, Z_DEFAULT_COMPRESSION);  // so that the finalizer can end it safely
  }
  return kk_cptr_raw_box(&kk_zs_free, z, ctx);
}

// Grow the output buffer so at least `need` bytes are free.
static uint8_t* kk_zs_reserve( uint8_t* buf, size_t len, size_t* cap, size_t need, kk_context_t* ctx ) {
  if (*cap - len >= need) return buf;
  size_t newcap = (*cap == 0 ? 16*1024 : *cap * 2);
  while (newcap - len < need) newcap *= 2;
  *cap = newcap;
  return (uint8_t*)kk_realloc(buf, newcap, ctx);
}

static void kk_zs_set_error( kk_zs_t* z, const char* what, int ret ) {
  const char* msg = (z->strm.msg != NULL ? z->strm.msg : (ret == Z_MEM_ERROR ? "out of memory" : (ret == Z_NEED_DICT ? "a preset dictionary is needed" : "invalid data")));
  snprintf(z->error, sizeof(z->error), "%s: %s", what, msg);
}

// Feed `input`; with `finish`, this is the last input. Returns the output produced.
// Returns the output and the error message (empty if there is none).
static kk_std_core_types__tuple2 kk_zs_push( kk_box_t bz, kk_bytes_t input, bool finish, kk_context_t* ctx ) {
  kk_zs_t* z = (kk_zs_t*)kk_cptr_raw_unbox_borrowed(bz,ctx);
  kk_ssize_t inlen;
  const uint8_t* in = kk_bytes_buf_borrow(input, &inlen, ctx);
  uint8_t* out = NULL;
  size_t len = 0;
  size_t cap = 0;
  if (z->error[0] != 0) goto done;
  z->strm.next_in = (Bytef*)in;
  z->strm.avail_in = (uInt)inlen;
  if (z->compress) {
    if (z->done) goto done;
    const int flush = (finish ? Z_FINISH : Z_NO_FLUSH);
    int ret;
    do {
      out = kk_zs_reserve(out, len, &cap, 16*1024, ctx);
      z->strm.next_out = out + len;
      z->strm.avail_out = (uInt)(cap - len);
      ret = deflate(&z->strm, flush);
      len = cap - z->strm.avail_out;
      if (ret == Z_STREAM_ERROR) { kk_zs_set_error(z, "compress", ret); break; }
    } while (z->strm.avail_out == 0 || (finish && ret != Z_STREAM_END));
    if (finish) z->done = true;
  }
  else {
    while (true) {
      if (z->done) {
        // after the end: gzip may have more members; skip zero padding, ignore other trailing data
        while (z->strm.avail_in > 0 && *z->strm.next_in == 0) { z->strm.next_in++; z->strm.avail_in--; }
        if (z->strm.avail_in == 0 || !z->gzip) break;
        inflateReset(&z->strm);
        z->done = false;
      }
      out = kk_zs_reserve(out, len, &cap, 16*1024, ctx);
      z->strm.next_out = out + len;
      z->strm.avail_out = (uInt)(cap - len);
      const int ret = inflate(&z->strm, Z_NO_FLUSH);
      len = cap - z->strm.avail_out;
      if (ret == Z_STREAM_END) { z->done = true; continue; }
      if (ret == Z_OK) {
        if (z->strm.avail_in == 0 && z->strm.avail_out > 0) break;
        continue;
      }
      if (ret == Z_BUF_ERROR) {
        if (z->strm.avail_in == 0) break;   // needs more input
        continue;                           // needs more output space
      }
      kk_zs_set_error(z, "decompress", ret);
      break;
    }
    if (finish && !z->done && z->error[0] == 0) {
      snprintf(z->error, sizeof(z->error), "decompress: unexpected end of the compressed data");
    }
  }
done:
  z->strm.next_in = NULL;
  z->strm.avail_in = 0;
  kk_bytes_drop(input,ctx);
  kk_string_t err = kk_string_alloc_from_qutf8(z->error, ctx);
  kk_box_drop(bz,ctx);
  kk_bytes_t b;
  if (len == 0) {
    if (out != NULL) kk_free(out,ctx);
    b = kk_bytes_empty();
  }
  else {
    b = kk_bytes_alloc_dupn((kk_ssize_t)len, out, ctx);
    kk_free(out,ctx);
  }
  return kk_std_core_types__new_Tuple2(kk_bytes_box(b), kk_string_box(err), ctx);
}

static kk_integer_t kk_zs_crc32( kk_bytes_t b, kk_integer_t init, kk_context_t* ctx ) {
  kk_ssize_t len;
  const uint8_t* p = kk_bytes_buf_borrow(b, &len, ctx);
  uLong crc = (uLong)kk_integer_clamp64(init,ctx);
  crc = crc32(crc, p, (uInt)len);
  kk_bytes_drop(b,ctx);
  return kk_integer_from_int64((int64_t)crc, ctx);
}

static kk_integer_t kk_zs_adler32( kk_bytes_t b, kk_integer_t init, kk_context_t* ctx ) {
  kk_ssize_t len;
  const uint8_t* p = kk_bytes_buf_borrow(b, &len, ctx);
  uLong a = (uLong)kk_integer_clamp64(init,ctx);
  a = adler32(a, p, (uInt)len);
  kk_bytes_drop(b,ctx);
  return kk_integer_from_int64((int64_t)a, ctx);
}
