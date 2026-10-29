/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

// A TLS client engine on mbedtls that works on in-memory buffers: the Koka
// side moves the encrypted bytes between the engine and a TCP socket
// (`tls-feed` / `tls-take-output`), so no event loop integration is needed here.

#include <stdlib.h>
#include <string.h>
#include <mbedtls/ssl.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/error.h>
#include <psa/crypto.h>

typedef struct kk_tls_s {
  mbedtls_ssl_context      ssl;
  mbedtls_ssl_config       conf;
  mbedtls_x509_crt         ca;
  mbedtls_entropy_context  entropy;
  mbedtls_ctr_drbg_context drbg;
  uint8_t* in;  size_t in_len;  size_t in_pos;  size_t in_cap;   // received ciphertext
  uint8_t* out; size_t out_len; size_t out_cap;                  // ciphertext to send
  bool     eof;          // the transport reached end-of-stream
  char     error[256];   // last error message
} kk_tls_t;

static void kk_tls_buf_append( uint8_t** buf, size_t* len, size_t* cap, const uint8_t* data, size_t n ) {
  if (*len + n > *cap) {
    size_t newcap = (*cap == 0 ? 16*1024 : *cap);
    while (newcap < *len + n) newcap *= 2;
    *buf = (uint8_t*)realloc(*buf, newcap);
    *cap = newcap;
  }
  memcpy(*buf + *len, data, n);
  *len += n;
}

static int kk_tls_bio_send( void* p, const unsigned char* data, size_t len ) {
  kk_tls_t* t = (kk_tls_t*)p;
  kk_tls_buf_append(&t->out, &t->out_len, &t->out_cap, data, len);
  return (int)len;
}

static int kk_tls_bio_recv( void* p, unsigned char* buf, size_t len ) {
  kk_tls_t* t = (kk_tls_t*)p;
  const size_t avail = t->in_len - t->in_pos;
  if (avail == 0) {
    return (t->eof ? 0 : MBEDTLS_ERR_SSL_WANT_READ);
  }
  const size_t n = (len < avail ? len : avail);
  memcpy(buf, t->in + t->in_pos, n);
  t->in_pos += n;
  if (t->in_pos == t->in_len) { t->in_pos = 0; t->in_len = 0; }
  return (int)n;
}

static void kk_tls_set_error( kk_tls_t* t, const char* what, int ret ) {
  char msg[160];
  msg[0] = 0;
  if (ret != 0) mbedtls_strerror(ret, msg, sizeof(msg));
  snprintf(t->error, sizeof(t->error), "%s%s%s", what, (msg[0] != 0 ? ": " : ""), msg);
}

// Load the system CA certificates; returns the number of files successfully loaded.
static int kk_tls_load_ca( kk_tls_t* t ) {
  const char* candidates[] = {
    getenv("SSL_CERT_FILE"), getenv("NIX_SSL_CERT_FILE"),
    "/etc/ssl/cert.pem",                         // macOS, Alpine
    "/etc/ssl/certs/ca-certificates.crt",        // Debian, Ubuntu, Arch, Nix
    "/etc/pki/tls/certs/ca-bundle.crt",          // Fedora, RHEL
    "/etc/ssl/ca-bundle.pem",                    // OpenSUSE
    NULL
  };
  for (size_t i = 0; i < sizeof(candidates)/sizeof(candidates[0]); i++) {
    const char* path = candidates[i];
    if (path == NULL || path[0] == 0) continue;
    if (mbedtls_x509_crt_parse_file(&t->ca, path) >= 0) return 1;
  }
  return 0;
}

static void kk_tls_free_fun( void* p, kk_block_t* b, kk_context_t* ctx ) {
  kk_unused(b); kk_unused(ctx);
  kk_tls_t* t = (kk_tls_t*)p;
  if (t == NULL) return;
  mbedtls_ssl_free(&t->ssl);
  mbedtls_ssl_config_free(&t->conf);
  mbedtls_x509_crt_free(&t->ca);
  mbedtls_ctr_drbg_free(&t->drbg);
  mbedtls_entropy_free(&t->entropy);
  free(t->in);
  free(t->out);
  free(t);
}

static kk_tls_t* kk_tls_unbox( kk_box_t b, kk_context_t* ctx ) {
  return (kk_tls_t*)kk_cptr_raw_unbox_borrowed(b, ctx);
}

// Create a TLS client for `host`. Check `kk_tls_error` for failures.
kk_box_t kk_tls_new( kk_string_t host, bool verify, kk_context_t* ctx ) {
  kk_tls_t* t = (kk_tls_t*)calloc(1, sizeof(kk_tls_t));
  mbedtls_ssl_init(&t->ssl);
  mbedtls_ssl_config_init(&t->conf);
  mbedtls_x509_crt_init(&t->ca);
  mbedtls_ctr_drbg_init(&t->drbg);
  mbedtls_entropy_init(&t->entropy);
  kk_box_t res = kk_cptr_raw_box(&kk_tls_free_fun, t, ctx);   // freed when the Koka value is dropped
  int ret;
  psa_status_t st = psa_crypto_init();
  if (st != PSA_SUCCESS) { snprintf(t->error, sizeof(t->error), "unable to initialize the crypto library (%d)", (int)st); goto done; }
  ret = mbedtls_ctr_drbg_seed(&t->drbg, mbedtls_entropy_func, &t->entropy, (const unsigned char*)"koka-tls", 8);
  if (ret != 0) { kk_tls_set_error(t, "unable to seed the random generator", ret); goto done; }
  ret = mbedtls_ssl_config_defaults(&t->conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
  if (ret != 0) { kk_tls_set_error(t, "unable to configure TLS", ret); goto done; }
  mbedtls_ssl_conf_rng(&t->conf, mbedtls_ctr_drbg_random, &t->drbg);
  if (verify) {
    if (kk_tls_load_ca(t) == 0) {
      snprintf(t->error, sizeof(t->error), "no CA certificates found (set SSL_CERT_FILE to a certificate bundle)");
      goto done;
    }
    mbedtls_ssl_conf_ca_chain(&t->conf, &t->ca, NULL);
    mbedtls_ssl_conf_authmode(&t->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
  }
  else {
    mbedtls_ssl_conf_authmode(&t->conf, MBEDTLS_SSL_VERIFY_NONE);
  }
  ret = mbedtls_ssl_setup(&t->ssl, &t->conf);
  if (ret != 0) { kk_tls_set_error(t, "unable to set up TLS", ret); goto done; }
  kk_with_string_as_qutf8_borrow(host, chost, ctx) {
    ret = mbedtls_ssl_set_hostname(&t->ssl, chost);
  }
  if (ret != 0) { kk_tls_set_error(t, "invalid host name", ret); goto done; }
  mbedtls_ssl_set_bio(&t->ssl, t, &kk_tls_bio_send, &kk_tls_bio_recv, NULL);
done:
  kk_string_drop(host, ctx);
  return res;
}

kk_string_t kk_tls_error( kk_box_t bt, kk_context_t* ctx ) {
  kk_tls_t* t = kk_tls_unbox(bt, ctx);
  kk_string_t s = kk_string_alloc_from_utf8(t->error, ctx);
  kk_box_drop(bt, ctx);
  return s;
}

// Advance the handshake: 0 = done, 1 = needs more input, -1 = error.
kk_integer_t kk_tls_handshake( kk_box_t bt, kk_context_t* ctx ) {
  kk_tls_t* t = kk_tls_unbox(bt, ctx);
  int status;
  const int ret = mbedtls_ssl_handshake(&t->ssl);
  if (ret == 0) status = 0;
  else if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) status = 1;
  else {
    if (ret == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED) {
      char vinfo[160];
      mbedtls_x509_crt_verify_info(vinfo, sizeof(vinfo), "", mbedtls_ssl_get_verify_result(&t->ssl));
      char* nl = strchr(vinfo, '\n');
      if (nl != NULL) *nl = 0;
      snprintf(t->error, sizeof(t->error), "certificate verification failed: %s", vinfo);
    }
    else if (t->eof) {
      snprintf(t->error, sizeof(t->error), "connection closed during the TLS handshake");
    }
    else {
      kk_tls_set_error(t, "TLS handshake failed", ret);
    }
    status = -1;
  }
  kk_box_drop(bt, ctx);
  return kk_integer_from_int(status, ctx);
}

// Take the pending ciphertext that must be sent to the peer.
kk_bytes_t kk_tls_take_output( kk_box_t bt, kk_context_t* ctx ) {
  kk_tls_t* t = kk_tls_unbox(bt, ctx);
  kk_bytes_t b = kk_bytes_alloc_dupn((kk_ssize_t)t->out_len, t->out, ctx);
  t->out_len = 0;
  kk_box_drop(bt, ctx);
  return b;
}

// Feed ciphertext received from the peer (an empty chunk with `eof` signals end-of-stream).
kk_unit_t kk_tls_feed( kk_box_t bt, kk_bytes_t data, bool eof, kk_context_t* ctx ) {
  kk_tls_t* t = kk_tls_unbox(bt, ctx);
  kk_ssize_t len;
  const uint8_t* p = kk_bytes_buf_borrow(data, &len, ctx);
  if (len > 0) kk_tls_buf_append(&t->in, &t->in_len, &t->in_cap, p, (size_t)len);
  if (eof) t->eof = true;
  kk_bytes_drop(data, ctx);
  kk_box_drop(bt, ctx);
  return kk_Unit;
}

// Read decrypted data: (0, data), (1, _) needs more input, (2, _) closed by the peer, (-1, _) error.
kk_std_core_types__tuple2 kk_tls_read( kk_box_t bt, kk_context_t* ctx ) {
  kk_tls_t* t = kk_tls_unbox(bt, ctx);
  uint8_t buf[16*1024];
  int status;
  kk_bytes_t data = kk_bytes_empty();
  const int ret = mbedtls_ssl_read(&t->ssl, buf, sizeof(buf));
  if (ret > 0) {
    status = 0;
    data = kk_bytes_alloc_dupn(ret, buf, ctx);
  }
  else if (ret == 0 || ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || ret == MBEDTLS_ERR_SSL_CONN_EOF) {
    status = 2;
  }
  else if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE
           #ifdef MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET
           || ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET
           #endif
          ) {
    status = (t->eof && t->in_len == 0 ? 2 : 1);
  }
  else {
    kk_tls_set_error(t, "TLS read failed", ret);
    status = -1;
  }
  kk_box_drop(bt, ctx);
  return kk_std_core_types__new_Tuple2(kk_integer_box(kk_integer_from_int(status, ctx), ctx), kk_bytes_box(data), ctx);
}

// Encrypt data (the ciphertext is available through `kk_tls_take_output`): 0 = ok, -1 = error.
kk_integer_t kk_tls_write( kk_box_t bt, kk_bytes_t data, kk_context_t* ctx ) {
  kk_tls_t* t = kk_tls_unbox(bt, ctx);
  kk_ssize_t len;
  const uint8_t* p = kk_bytes_buf_borrow(data, &len, ctx);
  int status = 0;
  kk_ssize_t pos = 0;
  while (pos < len) {
    const int ret = mbedtls_ssl_write(&t->ssl, p + pos, (size_t)(len - pos));
    if (ret > 0) pos += ret;
    else if (ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
    else { kk_tls_set_error(t, "TLS write failed", ret); status = -1; break; }
  }
  kk_bytes_drop(data, ctx);
  kk_box_drop(bt, ctx);
  return kk_integer_from_int(status, ctx);
}

kk_unit_t kk_tls_close_notify( kk_box_t bt, kk_context_t* ctx ) {
  kk_tls_t* t = kk_tls_unbox(bt, ctx);
  mbedtls_ssl_close_notify(&t->ssl);
  kk_box_drop(bt, ctx);
  return kk_Unit;
}
