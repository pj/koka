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
