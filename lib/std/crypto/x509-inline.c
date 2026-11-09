/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/*---------------------------------------------------------------------------
  Signature verification with mbedtls.
---------------------------------------------------------------------------*/
#include <string.h>
#include <mbedtls/pk.h>
#include <mbedtls/md.h>
#include <psa/crypto.h>

// hash: 1 = SHA-1, 256, 384, 512. Returns 1 if valid, 0 if not, -1 if the key is not supported.
static int32_t kk_x509_verify( kk_bytes_t spki, int32_t hash, kk_bytes_t data, kk_bytes_t sig, kk_context_t* ctx ) {
  static bool psa_ready = false;
  if (!psa_ready) { psa_crypto_init(); psa_ready = true; }
  kk_ssize_t klen, dlen, slen;
  const uint8_t* k = kk_bytes_buf_borrow(spki, &klen, ctx);
  const uint8_t* d = kk_bytes_buf_borrow(data, &dlen, ctx);
  const uint8_t* s = kk_bytes_buf_borrow(sig, &slen, ctx);
  mbedtls_md_type_t md = (hash == 1 ? MBEDTLS_MD_SHA1 : hash == 256 ? MBEDTLS_MD_SHA256 : hash == 384 ? MBEDTLS_MD_SHA384 : hash == 512 ? MBEDTLS_MD_SHA512 : MBEDTLS_MD_NONE);
  int32_t result = -1;
  mbedtls_pk_context pk;
  mbedtls_pk_init(&pk);
  const mbedtls_md_info_t* info = mbedtls_md_info_from_type(md);
  if (info != NULL && mbedtls_pk_parse_public_key(&pk, k, (size_t)klen) == 0) {
    unsigned char digest[MBEDTLS_MD_MAX_SIZE];
    if (mbedtls_md(info, d, (size_t)dlen, digest) == 0) {
      result = (mbedtls_pk_verify(&pk, md, digest, mbedtls_md_get_size(info), s, (size_t)slen) == 0 ? 1 : 0);
    }
  }
  mbedtls_pk_free(&pk);
  kk_bytes_drop(spki, ctx);
  kk_bytes_drop(data, ctx);
  kk_bytes_drop(sig, ctx);
  return result;
}
