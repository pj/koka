/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
// Traditional PKWARE zip encryption ("ZipCrypto").

static uint32_t kk_zipcrypto_table[256];
static bool kk_zipcrypto_table_init = false;

static uint32_t kk_zipcrypto_crc( uint32_t crc, uint8_t b ) {
  if (!kk_zipcrypto_table_init) {
    for (uint32_t n = 0; n < 256; n++) {
      uint32_t c = n;
      for (int k = 0; k < 8; k++) c = (c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1);
      kk_zipcrypto_table[n] = c;
    }
    kk_zipcrypto_table_init = true;
  }
  return (crc >> 8) ^ kk_zipcrypto_table[(crc ^ b) & 0xFF];
}

typedef struct kk_zipcrypto_keys_s { uint32_t k0, k1, k2; } kk_zipcrypto_keys_t;

static void kk_zipcrypto_update( kk_zipcrypto_keys_t* k, uint8_t c ) {
  k->k0 = kk_zipcrypto_crc(k->k0, c);
  k->k1 = (k->k1 + (k->k0 & 0xFF)) * 134775813u + 1;
  k->k2 = kk_zipcrypto_crc(k->k2, (uint8_t)(k->k1 >> 24));
}

static uint8_t kk_zipcrypto_stream( const kk_zipcrypto_keys_t* k ) {
  const uint32_t t = (k->k2 | 2) & 0xFFFF;
  return (uint8_t)(((t * (t ^ 1)) >> 8) & 0xFF);
}

// Encrypt (or decrypt) `data` with keys initialized from `password`.
static kk_bytes_t kk_zipcrypto( kk_bytes_t password, kk_bytes_t data, bool decrypt, kk_context_t* ctx ) {
  kk_ssize_t plen, len;
  const uint8_t* pw = kk_bytes_buf_borrow(password, &plen, ctx);
  const uint8_t* p = kk_bytes_buf_borrow(data, &len, ctx);
  kk_zipcrypto_keys_t k = { 0x12345678u, 0x23456789u, 0x34567890u };
  for (kk_ssize_t i = 0; i < plen; i++) kk_zipcrypto_update(&k, pw[i]);
  uint8_t* buf;
  kk_bytes_t out = (len > 0 ? kk_bytes_alloc_buf(len, &buf, ctx) : kk_bytes_empty());
  for (kk_ssize_t i = 0; i < len; i++) {
    const uint8_t s = kk_zipcrypto_stream(&k);
    const uint8_t c = p[i] ^ s;
    buf[i] = c;
    kk_zipcrypto_update(&k, decrypt ? c : p[i]);
  }
  kk_bytes_drop(password, ctx);
  kk_bytes_drop(data, ctx);
  return out;
}
