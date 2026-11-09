/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/*---------------------------------------------------------------------------
  Zstandard compression with libzstd. A (de)compressor is a boxed C pointer
  to a `kk_zstd_t`; its finalizer releases the context.
---------------------------------------------------------------------------*/
#include <stdio.h>
#include <string.h>
#include <zstd.h>

typedef struct kk_zstd_s {
  ZSTD_CCtx* cctx;
  ZSTD_DCtx* dctx;
  bool   done;          // finished compressing
  bool   in_frame;      // decompressing: inside a frame (the data so far ends in the middle of one)
  bool   any_input;     // decompressing: some data was given
  char   error[128];    // the last error ("" if none)
} kk_zstd_t;

static void kk_zstd_free( void* p, kk_block_t* block, kk_context_t* ctx ) {
  kk_unused(block);
  kk_zstd_t* z = (kk_zstd_t*)p;
  if (z->cctx != NULL) ZSTD_freeCCtx(z->cctx);
  if (z->dctx != NULL) ZSTD_freeDCtx(z->dctx);
  kk_free(z,ctx);
}

static kk_box_t kk_zstd_new( bool compress, kk_integer_t level, kk_context_t* ctx ) {
  const int lvl = kk_integer_clamp32(level,ctx);
  kk_zstd_t* z = (kk_zstd_t*)kk_malloc(sizeof(kk_zstd_t),ctx);
  memset(z, 0, sizeof(kk_zstd_t));
  if (compress) {
    z->cctx = ZSTD_createCCtx();
    if (z->cctx != NULL) {
      if (lvl >= ZSTD_minCLevel() && lvl <= ZSTD_maxCLevel()) ZSTD_CCtx_setParameter(z->cctx, ZSTD_c_compressionLevel, lvl);
      ZSTD_CCtx_setParameter(z->cctx, ZSTD_c_checksumFlag, 1);
    }
  }
  else {
    z->dctx = ZSTD_createDCtx();
  }
  if (z->cctx == NULL && z->dctx == NULL) snprintf(z->error, sizeof(z->error), "unable to initialize zstd");
  return kk_cptr_raw_box(&kk_zstd_free, z, ctx);
}

// Grow the output buffer so at least `need` bytes are free.
static uint8_t* kk_zstd_reserve( uint8_t* buf, size_t len, size_t* cap, size_t need, kk_context_t* ctx ) {
  if (*cap - len >= need) return buf;
  size_t newcap = (*cap == 0 ? 16*1024 : *cap * 2);
  while (newcap - len < need) newcap *= 2;
  *cap = newcap;
  return (uint8_t*)kk_realloc(buf, newcap, ctx);
}

// Feed `input`; with `finish`, this is the last input.
// Returns the output produced and the error message (empty if there is none).
static kk_std_core_types__tuple2 kk_zstd_push( kk_box_t bz, kk_bytes_t input, bool finish, kk_context_t* ctx ) {
  kk_zstd_t* z = (kk_zstd_t*)kk_cptr_raw_unbox_borrowed(bz,ctx);
  kk_ssize_t inlen;
  const uint8_t* inbuf = kk_bytes_buf_borrow(input, &inlen, ctx);
  ZSTD_inBuffer in = { inbuf, (size_t)inlen, 0 };
  uint8_t* out = NULL;
  size_t len = 0;
  size_t cap = 0;
  if (z->error[0] != 0) goto done;
  if (z->cctx != NULL) {
    if (z->done) goto done;
    const ZSTD_EndDirective mode = (finish ? ZSTD_e_end : ZSTD_e_continue);
    while (true) {
      out = kk_zstd_reserve(out, len, &cap, ZSTD_CStreamOutSize(), ctx);
      ZSTD_outBuffer ob = { out + len, cap - len, 0 };
      const size_t remaining = ZSTD_compressStream2(z->cctx, &ob, &in, mode);
      len += ob.pos;
      if (ZSTD_isError(remaining)) { snprintf(z->error, sizeof(z->error), "compress: %s", ZSTD_getErrorName(remaining)); break; }
      if (finish ? remaining == 0 : in.pos == in.size) break;
    }
    if (finish) z->done = true;
  }
  else {
    if (in.size > 0) z->any_input = true;
    while (in.pos < in.size) {
      out = kk_zstd_reserve(out, len, &cap, ZSTD_DStreamOutSize(), ctx);
      ZSTD_outBuffer ob = { out + len, cap - len, 0 };
      const size_t ret = ZSTD_decompressStream(z->dctx, &ob, &in);
      len += ob.pos;
      if (ZSTD_isError(ret)) { snprintf(z->error, sizeof(z->error), "decompress: %s", ZSTD_getErrorName(ret)); break; }
      z->in_frame = (ret != 0);   // 0: a frame was completed (another one may follow)
    }
    // flush output that is still buffered
    while (z->error[0] == 0 && z->in_frame) {
      out = kk_zstd_reserve(out, len, &cap, ZSTD_DStreamOutSize(), ctx);
      ZSTD_outBuffer ob = { out + len, cap - len, 0 };
      const size_t ret = ZSTD_decompressStream(z->dctx, &ob, &in);
      len += ob.pos;
      if (ZSTD_isError(ret)) { snprintf(z->error, sizeof(z->error), "decompress: %s", ZSTD_getErrorName(ret)); break; }
      z->in_frame = (ret != 0);
      if (ob.pos < ob.size) break;  // no more output without more input
    }
    if (finish && (z->in_frame || !z->any_input) && z->error[0] == 0) {
      snprintf(z->error, sizeof(z->error), "decompress: unexpected end of the compressed data");
    }
  }
done:
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
