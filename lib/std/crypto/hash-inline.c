/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.

  SHA-256 and SHA-1 (FIPS 180-4).
---------------------------------------------------------------------------*/
#include <string.h>

static inline uint32_t kk_sha_rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
static inline uint32_t kk_sha_rotl(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }

static const uint32_t kk_sha256_k[64] = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

static void kk_sha256_block(uint32_t h[8], const uint8_t* p) {
  uint32_t w[64];
  for (int i = 0; i < 16; i++) {
    w[i] = ((uint32_t)p[4*i] << 24) | ((uint32_t)p[4*i+1] << 16) | ((uint32_t)p[4*i+2] << 8) | (uint32_t)p[4*i+3];
  }
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = kk_sha_rotr(w[i-15],7) ^ kk_sha_rotr(w[i-15],18) ^ (w[i-15] >> 3);
    uint32_t s1 = kk_sha_rotr(w[i-2],17) ^ kk_sha_rotr(w[i-2],19) ^ (w[i-2] >> 10);
    w[i] = w[i-16] + s0 + w[i-7] + s1;
  }
  uint32_t a=h[0], b=h[1], c=h[2], d=h[3], e=h[4], f=h[5], g=h[6], hh=h[7];
  for (int i = 0; i < 64; i++) {
    uint32_t S1 = kk_sha_rotr(e,6) ^ kk_sha_rotr(e,11) ^ kk_sha_rotr(e,25);
    uint32_t ch = (e & f) ^ (~e & g);
    uint32_t t1 = hh + S1 + ch + kk_sha256_k[i] + w[i];
    uint32_t S0 = kk_sha_rotr(a,2) ^ kk_sha_rotr(a,13) ^ kk_sha_rotr(a,22);
    uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
    uint32_t t2 = S0 + mj;
    hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d; h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;
}

static void kk_sha1_block(uint32_t h[5], const uint8_t* p) {
  uint32_t w[80];
  for (int i = 0; i < 16; i++) {
    w[i] = ((uint32_t)p[4*i] << 24) | ((uint32_t)p[4*i+1] << 16) | ((uint32_t)p[4*i+2] << 8) | (uint32_t)p[4*i+3];
  }
  for (int i = 16; i < 80; i++) w[i] = kk_sha_rotl(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);
  uint32_t a=h[0], b=h[1], c=h[2], d=h[3], e=h[4];
  for (int i = 0; i < 80; i++) {
    uint32_t f, k;
    if (i < 20)      { f = (b & c) | (~b & d);          k = 0x5A827999; }
    else if (i < 40) { f = b ^ c ^ d;                   k = 0x6ED9EBA1; }
    else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
    else             { f = b ^ c ^ d;                   k = 0xCA62C1D6; }
    uint32_t t = kk_sha_rotl(a,5) + f + e + k + w[i];
    e = d; d = c; c = kk_sha_rotl(b,30); b = a; a = t;
  }
  h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d; h[4]+=e;
}

// Merkle-Damgard padding and block iteration shared by SHA-1 and SHA-256
static void kk_sha_run(const uint8_t* data, kk_ssize_t len, uint32_t* h, void (*block)(uint32_t*, const uint8_t*)) {
  kk_ssize_t i = 0;
  for (; i + 64 <= len; i += 64) block(h, data + i);
  uint8_t last[128];
  memset(last, 0, sizeof(last));
  const kk_ssize_t rem = len - i;
  memcpy(last, data + i, (size_t)rem);
  last[rem] = 0x80;
  const kk_ssize_t total = (rem + 9 <= 64 ? 64 : 128);
  const uint64_t bits = (uint64_t)len * 8;
  for (int j = 0; j < 8; j++) last[total - 1 - j] = (uint8_t)(bits >> (8*j));
  block(h, last);
  if (total == 128) block(h, last + 64);
}

static kk_bytes_t kk_sha_digest(kk_bytes_t b, bool sha256, kk_context_t* ctx) {
  kk_ssize_t len;
  const uint8_t* data = kk_bytes_buf_borrow(b, &len, ctx);
  uint32_t h[8] = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 };
  int nwords = 8;
  if (sha256) {
    kk_sha_run(data, len, h, &kk_sha256_block);
  }
  else {
    h[0]=0x67452301; h[1]=0xEFCDAB89; h[2]=0x98BADCFE; h[3]=0x10325476; h[4]=0xC3D2E1F0;
    nwords = 5;
    kk_sha_run(data, len, h, &kk_sha1_block);
  }
  kk_bytes_drop(b, ctx);
  uint8_t* out;
  kk_bytes_t res = kk_bytes_alloc_buf(4*nwords, &out, ctx);
  for (int i = 0; i < nwords; i++) {
    out[4*i] = (uint8_t)(h[i] >> 24); out[4*i+1] = (uint8_t)(h[i] >> 16);
    out[4*i+2] = (uint8_t)(h[i] >> 8); out[4*i+3] = (uint8_t)h[i];
  }
  return res;
}

/*---------------------------------------------------------------------------
  BLAKE2b and BLAKE2s (RFC 7693)
---------------------------------------------------------------------------*/
static const uint8_t kk_blake2_sigma[12][16] = {
  { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 },
  {14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 },
  {11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4 },
  { 7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8 },
  { 9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13 },
  { 2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9 },
  {12, 5, 1,15,14,13, 4,10, 0, 7, 6, 3, 9, 2, 8,11 },
  {13,11, 7,14,12, 1, 3, 9, 5, 0,15, 4, 8, 6, 2,10 },
  { 6,15,14, 9,11, 3, 0, 8,12, 2,13, 7, 1, 4,10, 5 },
  {10, 2, 8, 4, 7, 6, 1, 5,15,11, 9,14, 3,12,13, 0 },
  { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 },
  {14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 }
};

static const uint64_t kk_blake2b_iv[8] = {
  0x6A09E667F3BCC908ULL, 0xBB67AE8584CAA73BULL, 0x3C6EF372FE94F82BULL, 0xA54FF53A5F1D36F1ULL,
  0x510E527FADE682D1ULL, 0x9B05688C2B3E6C1FULL, 0x1F83D9ABFB41BD6BULL, 0x5BE0CD19137E2179ULL
};

static const uint32_t kk_blake2s_iv[8] = {
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
};

static inline uint64_t kk_rotr64(uint64_t x, int n) { return (x >> n) | (x << (64 - n)); }

static void kk_blake2b_compress(uint64_t h[8], const uint8_t block[128], uint64_t t, bool last) {
  uint64_t v[16], m[16];
  for (int i = 0; i < 16; i++) {
    uint64_t w = 0;
    for (int j = 7; j >= 0; j--) w = (w << 8) | block[8*i + j];
    m[i] = w;
  }
  for (int i = 0; i < 8; i++) { v[i] = h[i]; v[i+8] = kk_blake2b_iv[i]; }
  v[12] ^= t;
  if (last) v[14] = ~v[14];
  #define KK_B2B_G(a,b,c,d,x,y) \
    v[a] = v[a] + v[b] + x; v[d] = kk_rotr64(v[d] ^ v[a], 32); \
    v[c] = v[c] + v[d];     v[b] = kk_rotr64(v[b] ^ v[c], 24); \
    v[a] = v[a] + v[b] + y; v[d] = kk_rotr64(v[d] ^ v[a], 16); \
    v[c] = v[c] + v[d];     v[b] = kk_rotr64(v[b] ^ v[c], 63);
  for (int r = 0; r < 12; r++) {
    const uint8_t* s = kk_blake2_sigma[r];
    KK_B2B_G(0, 4,  8, 12, m[s[ 0]], m[s[ 1]]);
    KK_B2B_G(1, 5,  9, 13, m[s[ 2]], m[s[ 3]]);
    KK_B2B_G(2, 6, 10, 14, m[s[ 4]], m[s[ 5]]);
    KK_B2B_G(3, 7, 11, 15, m[s[ 6]], m[s[ 7]]);
    KK_B2B_G(0, 5, 10, 15, m[s[ 8]], m[s[ 9]]);
    KK_B2B_G(1, 6, 11, 12, m[s[10]], m[s[11]]);
    KK_B2B_G(2, 7,  8, 13, m[s[12]], m[s[13]]);
    KK_B2B_G(3, 4,  9, 14, m[s[14]], m[s[15]]);
  }
  #undef KK_B2B_G
  for (int i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i+8];
}

static void kk_blake2s_compress(uint32_t h[8], const uint8_t block[64], uint64_t t, bool last) {
  uint32_t v[16], m[16];
  for (int i = 0; i < 16; i++) {
    m[i] = (uint32_t)block[4*i] | ((uint32_t)block[4*i+1] << 8) | ((uint32_t)block[4*i+2] << 16) | ((uint32_t)block[4*i+3] << 24);
  }
  for (int i = 0; i < 8; i++) { v[i] = h[i]; v[i+8] = kk_blake2s_iv[i]; }
  v[12] ^= (uint32_t)t;
  v[13] ^= (uint32_t)(t >> 32);
  if (last) v[14] = ~v[14];
  #define KK_B2S_G(a,b,c,d,x,y) \
    v[a] = v[a] + v[b] + x; v[d] = kk_sha_rotr(v[d] ^ v[a], 16); \
    v[c] = v[c] + v[d];     v[b] = kk_sha_rotr(v[b] ^ v[c], 12); \
    v[a] = v[a] + v[b] + y; v[d] = kk_sha_rotr(v[d] ^ v[a], 8); \
    v[c] = v[c] + v[d];     v[b] = kk_sha_rotr(v[b] ^ v[c], 7);
  for (int r = 0; r < 10; r++) {
    const uint8_t* s = kk_blake2_sigma[r];
    KK_B2S_G(0, 4,  8, 12, m[s[ 0]], m[s[ 1]]);
    KK_B2S_G(1, 5,  9, 13, m[s[ 2]], m[s[ 3]]);
    KK_B2S_G(2, 6, 10, 14, m[s[ 4]], m[s[ 5]]);
    KK_B2S_G(3, 7, 11, 15, m[s[ 6]], m[s[ 7]]);
    KK_B2S_G(0, 5, 10, 15, m[s[ 8]], m[s[ 9]]);
    KK_B2S_G(1, 6, 11, 12, m[s[10]], m[s[11]]);
    KK_B2S_G(2, 7,  8, 13, m[s[12]], m[s[13]]);
    KK_B2S_G(3, 4,  9, 14, m[s[14]], m[s[15]]);
  }
  #undef KK_B2S_G
  for (int i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i+8];
}

// BLAKE2b (`big`) or BLAKE2s with an output of `outlen` bytes and an optional key.
static kk_bytes_t kk_blake2_digest(kk_bytes_t data, kk_integer_t size, kk_bytes_t key, bool big, kk_context_t* ctx) {
  const kk_ssize_t bb = (big ? 128 : 64);    // block size
  const kk_ssize_t maxout = (big ? 64 : 32);
  kk_ssize_t outlen = kk_integer_clamp_ssize_t(size,ctx);
  if (outlen < 1) outlen = 1;
  if (outlen > maxout) outlen = maxout;
  kk_ssize_t len, keylen;
  const uint8_t* p = kk_bytes_buf_borrow(data, &len, ctx);
  const uint8_t* k = kk_bytes_buf_borrow(key, &keylen, ctx);
  if (keylen > maxout) keylen = maxout;
  uint64_t hb[8]; uint32_t hs[8];
  for (int i = 0; i < 8; i++) { hb[i] = kk_blake2b_iv[i]; hs[i] = kk_blake2s_iv[i]; }
  const uint64_t param = 0x01010000 ^ ((uint64_t)keylen << 8) ^ (uint64_t)outlen;
  hb[0] ^= param; hs[0] ^= (uint32_t)param;
  uint8_t block[128];
  uint64_t t = 0;
  kk_ssize_t pos = 0;
  // the key is the first (padded) block
  const kk_ssize_t total = (keylen > 0 ? bb : 0) + len;
  // process all blocks but the last one
  kk_ssize_t remaining = total;
  bool have_key_block = (keylen > 0);
  while (remaining > bb) {
    if (have_key_block) {
      memset(block, 0, sizeof(block));
      memcpy(block, k, (size_t)keylen);
      have_key_block = false;
    }
    else {
      memcpy(block, p + pos, (size_t)bb);
      pos += bb;
    }
    t += (uint64_t)bb;
    if (big) kk_blake2b_compress(hb, block, t, false); else kk_blake2s_compress(hs, block, t, false);
    remaining -= bb;
  }
  // the last block (possibly empty)
  memset(block, 0, sizeof(block));
  if (have_key_block) {
    memcpy(block, k, (size_t)keylen);
    t += (uint64_t)bb;
  }
  else {
    memcpy(block, p + pos, (size_t)(len - pos));
    t += (uint64_t)(len - pos);
  }
  if (big) kk_blake2b_compress(hb, block, t, true); else kk_blake2s_compress(hs, block, t, true);
  uint8_t out[64];
  for (int i = 0; i < 64; i++) {
    out[i] = (big ? (uint8_t)(hb[i/8] >> (8*(i%8))) : (i < 32 ? (uint8_t)(hs[i/4] >> (8*(i%4))) : 0));
  }
  kk_bytes_drop(data,ctx);
  kk_bytes_drop(key,ctx);
  return kk_bytes_alloc_dupn(outlen, out, ctx);
}

/*---------------------------------------------------------------------------
  BLAKE3 (a port of the reference implementation)
---------------------------------------------------------------------------*/
#define KK_B3_CHUNK_START         1
#define KK_B3_CHUNK_END           2
#define KK_B3_PARENT              4
#define KK_B3_ROOT                8
#define KK_B3_KEYED_HASH         16
#define KK_B3_DERIVE_KEY_CONTEXT 32
#define KK_B3_DERIVE_KEY_MATERIAL 64

static const uint8_t kk_b3_perm[16] = { 2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8 };

static void kk_b3_compress(const uint32_t cv[8], const uint32_t block[16], uint64_t counter, uint32_t block_len, uint32_t flags, uint32_t out[16]) {
  uint32_t s[16], m[16], t[16];
  for (int i = 0; i < 8; i++) s[i] = cv[i];
  s[8] = kk_blake2s_iv[0]; s[9] = kk_blake2s_iv[1]; s[10] = kk_blake2s_iv[2]; s[11] = kk_blake2s_iv[3];
  s[12] = (uint32_t)counter; s[13] = (uint32_t)(counter >> 32); s[14] = block_len; s[15] = flags;
  for (int i = 0; i < 16; i++) m[i] = block[i];
  #define KK_B3_G(a,b,c,d,x,y) \
    s[a] = s[a] + s[b] + x; s[d] = kk_sha_rotr(s[d] ^ s[a], 16); \
    s[c] = s[c] + s[d];     s[b] = kk_sha_rotr(s[b] ^ s[c], 12); \
    s[a] = s[a] + s[b] + y; s[d] = kk_sha_rotr(s[d] ^ s[a], 8); \
    s[c] = s[c] + s[d];     s[b] = kk_sha_rotr(s[b] ^ s[c], 7);
  for (int r = 0; r < 7; r++) {
    KK_B3_G(0, 4,  8, 12, m[ 0], m[ 1]);
    KK_B3_G(1, 5,  9, 13, m[ 2], m[ 3]);
    KK_B3_G(2, 6, 10, 14, m[ 4], m[ 5]);
    KK_B3_G(3, 7, 11, 15, m[ 6], m[ 7]);
    KK_B3_G(0, 5, 10, 15, m[ 8], m[ 9]);
    KK_B3_G(1, 6, 11, 12, m[10], m[11]);
    KK_B3_G(2, 7,  8, 13, m[12], m[13]);
    KK_B3_G(3, 4,  9, 14, m[14], m[15]);
    if (r < 6) {
      for (int i = 0; i < 16; i++) t[i] = m[kk_b3_perm[i]];
      for (int i = 0; i < 16; i++) m[i] = t[i];
    }
  }
  #undef KK_B3_G
  for (int i = 0; i < 8; i++) { out[i] = s[i] ^ s[i+8]; out[i+8] = s[i+8] ^ cv[i]; }
}

static void kk_b3_words(const uint8_t* p, kk_ssize_t len, uint32_t w[16]) {
  uint8_t block[64];
  memset(block, 0, 64);
  memcpy(block, p, (size_t)len);
  for (int i = 0; i < 16; i++) {
    w[i] = (uint32_t)block[4*i] | ((uint32_t)block[4*i+1] << 8) | ((uint32_t)block[4*i+2] << 16) | ((uint32_t)block[4*i+3] << 24);
  }
}

// The output of a node: enough to compute its chaining value or the root output.
typedef struct kk_b3_output_s {
  uint32_t cv[8];
  uint32_t block[16];
  uint64_t counter;
  uint32_t block_len;
  uint32_t flags;
} kk_b3_output_t;

static void kk_b3_output_cv(const kk_b3_output_t* o, uint32_t cv[8]) {
  uint32_t out[16];
  kk_b3_compress(o->cv, o->block, o->counter, o->block_len, o->flags, out);
  for (int i = 0; i < 8; i++) cv[i] = out[i];
}

// The output of a chunk of at most 1024 bytes.
static kk_b3_output_t kk_b3_chunk(const uint32_t key[8], const uint8_t* p, kk_ssize_t len, uint64_t chunk_counter, uint32_t flags) {
  uint32_t cv[8];
  for (int i = 0; i < 8; i++) cv[i] = key[i];
  kk_ssize_t pos = 0;
  int blocks = 0;
  while (len - pos > 64) {
    uint32_t w[16], out[16];
    kk_b3_words(p + pos, 64, w);
    kk_b3_compress(cv, w, chunk_counter, 64, flags | (blocks == 0 ? KK_B3_CHUNK_START : 0), out);
    for (int i = 0; i < 8; i++) cv[i] = out[i];
    pos += 64;
    blocks++;
  }
  kk_b3_output_t o;
  for (int i = 0; i < 8; i++) o.cv[i] = cv[i];
  kk_b3_words(p + pos, len - pos, o.block);
  o.counter = chunk_counter;
  o.block_len = (uint32_t)(len - pos);
  o.flags = flags | (blocks == 0 ? KK_B3_CHUNK_START : 0) | KK_B3_CHUNK_END;
  return o;
}

static kk_b3_output_t kk_b3_parent(const uint32_t left[8], const uint32_t right[8], const uint32_t key[8], uint32_t flags) {
  kk_b3_output_t o;
  for (int i = 0; i < 8; i++) { o.cv[i] = key[i]; o.block[i] = left[i]; o.block[i+8] = right[i]; }
  o.counter = 0;
  o.block_len = 64;
  o.flags = flags | KK_B3_PARENT;
  return o;
}

// Hash `p` with the key words and flags; write `outlen` bytes to `out`.
static void kk_b3_hash(const uint32_t key[8], uint32_t flags, const uint8_t* p, kk_ssize_t len, uint8_t* out, kk_ssize_t outlen) {
  uint32_t stack[54][8];   // enough for 2^54 chunks
  int depth = 0;
  uint64_t chunk = 0;
  kk_ssize_t pos = 0;
  // all chunks but the last are merged into the stack of chaining values
  while (len - pos > 1024) {
    kk_b3_output_t o = kk_b3_chunk(key, p + pos, 1024, chunk, flags);
    uint32_t cv[8];
    kk_b3_output_cv(&o, cv);
    chunk++;
    uint64_t total = chunk;
    while ((total & 1) == 0) {
      depth--;
      kk_b3_output_t po = kk_b3_parent(stack[depth], cv, key, flags);
      kk_b3_output_cv(&po, cv);
      total >>= 1;
    }
    for (int i = 0; i < 8; i++) stack[depth][i] = cv[i];
    depth++;
    pos += 1024;
  }
  kk_b3_output_t o = kk_b3_chunk(key, p + pos, len - pos, chunk, flags);
  while (depth > 0) {
    depth--;
    uint32_t cv[8];
    kk_b3_output_cv(&o, cv);
    o = kk_b3_parent(stack[depth], cv, key, flags);
  }
  // the root output, as long as needed
  uint64_t counter = 0;
  kk_ssize_t written = 0;
  while (written < outlen) {
    uint32_t words[16];
    kk_b3_compress(o.cv, o.block, counter, o.block_len, o.flags | KK_B3_ROOT, words);
    for (int i = 0; i < 64 && written < outlen; i++) {
      out[written++] = (uint8_t)(words[i/4] >> (8*(i%4)));
    }
    counter++;
  }
}

// mode 0: plain, 1: keyed (`key` has 32 bytes), 2: derive a key (`key` is the context)
static kk_bytes_t kk_blake3_digest(kk_bytes_t data, kk_integer_t size, kk_bytes_t key, kk_integer_t mode, kk_context_t* ctx) {
  kk_ssize_t outlen = kk_integer_clamp_ssize_t(size,ctx);
  if (outlen < 0) outlen = 0;
  const int m = kk_integer_clamp32(mode,ctx);
  kk_ssize_t len, keylen;
  const uint8_t* p = kk_bytes_buf_borrow(data, &len, ctx);
  const uint8_t* k = kk_bytes_buf_borrow(key, &keylen, ctx);
  uint32_t kw[8];
  uint32_t flags = 0;
  for (int i = 0; i < 8; i++) kw[i] = kk_blake2s_iv[i];
  if (m == 1) {
    uint32_t w[16];
    kk_b3_words(k, (keylen > 32 ? 32 : keylen), w);
    for (int i = 0; i < 8; i++) kw[i] = w[i];
    flags = KK_B3_KEYED_HASH;
  }
  else if (m == 2) {
    uint8_t ck[32];
    kk_b3_hash(kw, KK_B3_DERIVE_KEY_CONTEXT, k, keylen, ck, 32);
    uint32_t w[16];
    kk_b3_words(ck, 32, w);
    for (int i = 0; i < 8; i++) kw[i] = w[i];
    flags = KK_B3_DERIVE_KEY_MATERIAL;
  }
  uint8_t* buf;
  kk_bytes_t out = kk_bytes_alloc_buf(outlen, &buf, ctx);
  if (outlen > 0) kk_b3_hash(kw, flags, p, len, buf, outlen);
  kk_bytes_drop(data,ctx);
  kk_bytes_drop(key,ctx);
  return out;
}
