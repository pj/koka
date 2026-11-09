/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/*---------------------------------------------------------------------------
  Brotli compression with the reference library. A (de)compressor is a boxed
  C pointer to a `kk_br_t`; its finalizer releases the encoder or decoder.
---------------------------------------------------------------------------*/
#include <stdio.h>
#include <string.h>
#include <brotli/encode.h>
#include <brotli/decode.h>

typedef struct kk_br_s {
  BrotliEncoderState* enc;
  BrotliDecoderState* dec;
  bool done;            // finished (compressing), or the end of the data was reached (decompressing)
  char error[128];      // the last error ("" if none)
} kk_br_t;

static void kk_br_free( void* p, kk_block_t* block, kk_context_t* ctx ) {
  kk_unused(block);
  kk_br_t* z = (kk_br_t*)p;
  if (z->enc != NULL) BrotliEncoderDestroyInstance(z->enc);
  if (z->dec != NULL) BrotliDecoderDestroyInstance(z->dec);
  kk_free(z,ctx);
}

static kk_box_t kk_br_new( bool compress, kk_integer_t quality, kk_integer_t window, kk_context_t* ctx ) {
  int q = kk_integer_clamp32(quality,ctx);
  int w = kk_integer_clamp32(window,ctx);
  kk_br_t* z = (kk_br_t*)kk_malloc(sizeof(kk_br_t),ctx);
  memset(z, 0, sizeof(kk_br_t));
  if (compress) {
    z->enc = BrotliEncoderCreateInstance(NULL, NULL, NULL);
    if (z->enc != NULL) {
      if (q >= BROTLI_MIN_QUALITY && q <= BROTLI_MAX_QUALITY) BrotliEncoderSetParameter(z->enc, BROTLI_PARAM_QUALITY, (uint32_t)q);
      if (w >= BROTLI_MIN_WINDOW_BITS && w <= BROTLI_MAX_WINDOW_BITS) BrotliEncoderSetParameter(z->enc, BROTLI_PARAM_LGWIN, (uint32_t)w);
    }
  }
  else {
    z->dec = BrotliDecoderCreateInstance(NULL, NULL, NULL);
  }
  if (z->enc == NULL && z->dec == NULL) snprintf(z->error, sizeof(z->error), "unable to initialize brotli");
  return kk_cptr_raw_box(&kk_br_free, z, ctx);
}

// Grow the output buffer so at least `need` bytes are free.
static uint8_t* kk_br_reserve( uint8_t* buf, size_t len, size_t* cap, size_t need, kk_context_t* ctx ) {
  if (*cap - len >= need) return buf;
  size_t newcap = (*cap == 0 ? 16*1024 : *cap * 2);
  while (newcap - len < need) newcap *= 2;
  *cap = newcap;
  return (uint8_t*)kk_realloc(buf, newcap, ctx);
}

// Feed `input`; with `finish`, this is the last input.
// Returns the output produced and the error message (empty if there is none).
static kk_std_core_types__tuple2 kk_br_push( kk_box_t bz, kk_bytes_t input, bool finish, kk_context_t* ctx ) {
  kk_br_t* z = (kk_br_t*)kk_cptr_raw_unbox_borrowed(bz,ctx);
  kk_ssize_t inlen;
  const uint8_t* next_in = kk_bytes_buf_borrow(input, &inlen, ctx);
  size_t avail_in = (size_t)inlen;
  uint8_t* out = NULL;
  size_t len = 0;
  size_t cap = 0;
  if (z->error[0] != 0 || z->done) goto done;
  if (z->enc != NULL) {
    const BrotliEncoderOperation op = (finish ? BROTLI_OPERATION_FINISH : BROTLI_OPERATION_PROCESS);
    while (true) {
      out = kk_br_reserve(out, len, &cap, 16*1024, ctx);
      size_t avail_out = cap - len;
      uint8_t* next_out = out + len;
      if (!BrotliEncoderCompressStream(z->enc, op, &avail_in, &next_in, &avail_out, &next_out, NULL)) {
        snprintf(z->error, sizeof(z->error), "compress: brotli encoder failed");
        break;
      }
      len = cap - avail_out;
      if (finish ? BrotliEncoderIsFinished(z->enc) : (avail_in == 0 && !BrotliEncoderHasMoreOutput(z->enc))) break;
    }
    if (finish) z->done = true;
  }
  else {
    while (true) {
      out = kk_br_reserve(out, len, &cap, 16*1024, ctx);
      size_t avail_out = cap - len;
      uint8_t* next_out = out + len;
      const BrotliDecoderResult res = BrotliDecoderDecompressStream(z->dec, &avail_in, &next_in, &avail_out, &next_out, NULL);
      len = cap - avail_out;
      if (res == BROTLI_DECODER_RESULT_SUCCESS) { z->done = true; break; }  // trailing data is ignored
      if (res == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) continue;
      if (res == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT) break;
      snprintf(z->error, sizeof(z->error), "decompress: %s", BrotliDecoderErrorString(BrotliDecoderGetErrorCode(z->dec)));
      break;
    }
    if (finish && !z->done && z->error[0] == 0) {
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
