/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

// A TLS client and server engine on mbedtls that works on in-memory buffers: the Koka
// side moves the encrypted bytes between the engine and a TCP socket
// (`tls-feed` / `tls-take-output`), so no event loop integration is needed here.

#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <mbedtls/ssl.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/error.h>
#include <mbedtls/pk.h>
#include <psa/crypto.h>

// A server configuration (certificate chain and private key), shared by the
// engines of all connections accepted with it.
#define KK_TLS_MAX_ALPN 8

#define KK_TLS_MAX_SNI 64

typedef struct kk_tls_conf_s {
  mbedtls_ssl_config       conf;
  mbedtls_x509_crt         cert;
  mbedtls_pk_context       key;
  mbedtls_x509_crt         client_ca;   // to verify client certificates
  int                      sni_count;   // certificates selected by the server name (SNI)
  char*                    sni_names[KK_TLS_MAX_SNI];
  mbedtls_x509_crt         sni_cert[KK_TLS_MAX_SNI];
  mbedtls_pk_context       sni_key[KK_TLS_MAX_SNI];
  char*        alpn_buf;                // ALPN protocol names (NUL separated)
  const char*  alpn[KK_TLS_MAX_ALPN+1];
  mbedtls_entropy_context  entropy;
  mbedtls_ctr_drbg_context drbg;
  char     error[256];   // set if the configuration is invalid
} kk_tls_conf_t;

typedef struct kk_tls_s {
  mbedtls_ssl_context      ssl;
  mbedtls_ssl_config       conf;
  mbedtls_x509_crt         ca;
  mbedtls_x509_crt         own_cert;    // client certificate (clients only)
  mbedtls_pk_context       own_key;
  char*        alpn_buf;
  const char*  alpn[KK_TLS_MAX_ALPN+1];
  mbedtls_entropy_context  entropy;
  mbedtls_ctr_drbg_context drbg;
  uint8_t* in;  size_t in_len;  size_t in_pos;  size_t in_cap;   // received ciphertext
  uint8_t* out; size_t out_len; size_t out_cap;                  // ciphertext to send
  bool     eof;          // the transport reached end-of-stream
  char     error[256];   // last error message
  bool     has_sconf;
  kk_box_t sconf;        // the server configuration (server engines only); kept alive by this engine
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

static void kk_tls_format_error( char* buf, size_t size, const char* what, int ret ) {
  char msg[160];
  msg[0] = 0;
  if (ret != 0) mbedtls_strerror(ret, msg, sizeof(msg));
  snprintf(buf, size, "%s%s%s", what, (msg[0] != 0 ? ": " : ""), msg);
}

static void kk_tls_set_error( kk_tls_t* t, const char* what, int ret ) {
  kk_tls_format_error(t->error, sizeof(t->error), what, ret);
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

// Configure the ALPN protocols from a comma separated list (if not empty).
static int kk_tls_conf_alpn( mbedtls_ssl_config* conf, kk_string_t alpn, char** buf, const char** list, kk_context_t* ctx ) {
  int ret = 0;
  kk_with_string_as_qutf8_borrow(alpn, calpn, ctx) {
    if (calpn[0] != 0) {
      *buf = strdup(calpn);
      size_t n = 0;
      char* p = *buf;
      while (p != NULL && n < KK_TLS_MAX_ALPN) {
        char* comma = strchr(p, ',');
        if (comma != NULL) *comma = 0;
        if (*p != 0) list[n++] = p;
        p = (comma == NULL ? NULL : comma + 1);
      }
      list[n] = NULL;
      ret = mbedtls_ssl_conf_alpn_protocols(conf, list);
    }
  }
  return ret;
}

static void kk_tls_free_fun( void* p, kk_block_t* b, kk_context_t* ctx ) {
  kk_unused(b);
  kk_tls_t* t = (kk_tls_t*)p;
  if (t == NULL) return;
  mbedtls_ssl_free(&t->ssl);
  if (t->has_sconf) kk_box_drop(t->sconf, ctx);   // after the ssl context that refers to it
  mbedtls_ssl_config_free(&t->conf);
  mbedtls_x509_crt_free(&t->ca);
  mbedtls_x509_crt_free(&t->own_cert);
  mbedtls_pk_free(&t->own_key);
  mbedtls_ctr_drbg_free(&t->drbg);
  mbedtls_entropy_free(&t->entropy);
  free(t->alpn_buf);
  free(t->in);
  free(t->out);
  free(t);
}

static kk_tls_t* kk_tls_unbox( kk_box_t b, kk_context_t* ctx ) {
  return (kk_tls_t*)kk_cptr_raw_unbox_borrowed(b, ctx);
}

static kk_tls_t* kk_tls_alloc( kk_box_t* res, kk_context_t* ctx ) {
  kk_tls_t* t = (kk_tls_t*)calloc(1, sizeof(kk_tls_t));
  mbedtls_ssl_init(&t->ssl);
  mbedtls_ssl_config_init(&t->conf);
  mbedtls_x509_crt_init(&t->ca);
  mbedtls_x509_crt_init(&t->own_cert);
  mbedtls_pk_init(&t->own_key);
  mbedtls_ctr_drbg_init(&t->drbg);
  mbedtls_entropy_init(&t->entropy);
  *res = kk_cptr_raw_box(&kk_tls_free_fun, t, ctx);   // freed when the Koka value is dropped
  return t;
}

// Create a TLS client for `host`. With `verify`, the server certificate is
// checked against `ca` (PEM certificates) or, if `ca` is empty, the system CA
// certificates. If `cert` is not empty, it is presented (with private key
// `key`) as the client certificate. `alpn` is a comma separated list of
// protocols to offer. Check `kk_tls_error` for failures.
kk_box_t kk_tls_new( kk_string_t host, bool verify, kk_string_t ca, kk_string_t cert, kk_string_t key, kk_string_t alpn, kk_context_t* ctx ) {
  kk_box_t res;
  kk_tls_t* t = kk_tls_alloc(&res, ctx);
  int ret;
  psa_status_t st = psa_crypto_init();
  if (st != PSA_SUCCESS) { snprintf(t->error, sizeof(t->error), "unable to initialize the crypto library (%d)", (int)st); goto done; }
  ret = mbedtls_ctr_drbg_seed(&t->drbg, mbedtls_entropy_func, &t->entropy, (const unsigned char*)"koka-tls", 8);
  if (ret != 0) { kk_tls_set_error(t, "unable to seed the random generator", ret); goto done; }
  ret = mbedtls_ssl_config_defaults(&t->conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
  if (ret != 0) { kk_tls_set_error(t, "unable to configure TLS", ret); goto done; }
  mbedtls_ssl_conf_rng(&t->conf, mbedtls_ctr_drbg_random, &t->drbg);
  if (verify && kk_string_len_borrow(ca, ctx) > 0) {
    kk_with_string_as_qutf8_borrow(ca, cca, ctx) {
      ret = mbedtls_x509_crt_parse(&t->ca, (const unsigned char*)cca, strlen(cca) + 1);
    }
    if (ret != 0) { kk_tls_set_error(t, "invalid CA certificate", ret); goto done; }
    mbedtls_ssl_conf_ca_chain(&t->conf, &t->ca, NULL);
    mbedtls_ssl_conf_authmode(&t->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
  }
  else if (verify) {
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
  if (kk_string_len_borrow(cert, ctx) > 0) {
    kk_with_string_as_qutf8_borrow(cert, ccert, ctx) {
      ret = mbedtls_x509_crt_parse(&t->own_cert, (const unsigned char*)ccert, strlen(ccert) + 1);
    }
    if (ret != 0) { kk_tls_set_error(t, "invalid client certificate", ret); goto done; }
    kk_with_string_as_qutf8_borrow(key, ckey, ctx) {
      ret = mbedtls_pk_parse_key(&t->own_key, (const unsigned char*)ckey, strlen(ckey) + 1, NULL, 0, mbedtls_ctr_drbg_random, &t->drbg);
    }
    if (ret != 0) { kk_tls_set_error(t, "invalid client private key", ret); goto done; }
    ret = mbedtls_ssl_conf_own_cert(&t->conf, &t->own_cert, &t->own_key);
    if (ret != 0) { kk_tls_set_error(t, "the client private key does not fit the certificate", ret); goto done; }
  }
  ret = kk_tls_conf_alpn(&t->conf, alpn, &t->alpn_buf, t->alpn, ctx);
  if (ret != 0) { kk_tls_set_error(t, "invalid ALPN protocols", ret); goto done; }
  ret = mbedtls_ssl_setup(&t->ssl, &t->conf);
  if (ret != 0) { kk_tls_set_error(t, "unable to set up TLS", ret); goto done; }
  kk_with_string_as_qutf8_borrow(host, chost, ctx) {
    ret = mbedtls_ssl_set_hostname(&t->ssl, chost);
  }
  if (ret != 0) { kk_tls_set_error(t, "invalid host name", ret); goto done; }
  mbedtls_ssl_set_bio(&t->ssl, t, &kk_tls_bio_send, &kk_tls_bio_recv, NULL);
done:
  kk_string_drop(host, ctx);
  kk_string_drop(ca, ctx);
  kk_string_drop(cert, ctx);
  kk_string_drop(key, ctx);
  kk_string_drop(alpn, ctx);
  return res;
}

// ---------------------------------------------------------------------------
// Servers
// ---------------------------------------------------------------------------

static void kk_tls_conf_free_fun( void* p, kk_block_t* b, kk_context_t* ctx ) {
  kk_unused(b); kk_unused(ctx);
  kk_tls_conf_t* c = (kk_tls_conf_t*)p;
  if (c == NULL) return;
  mbedtls_ssl_config_free(&c->conf);
  mbedtls_x509_crt_free(&c->cert);
  mbedtls_x509_crt_free(&c->client_ca);
  mbedtls_pk_free(&c->key);
  for (int i = 0; i < c->sni_count; i++) {
    free(c->sni_names[i]);
    mbedtls_x509_crt_free(&c->sni_cert[i]);
    mbedtls_pk_free(&c->sni_key[i]);
  }
  free(c->alpn_buf);
  mbedtls_ctr_drbg_free(&c->drbg);
  mbedtls_entropy_free(&c->entropy);
  free(c);
}

// Does a server name match a host pattern (a name, or `*.domain` for one label)?
static bool kk_tls_name_matches( const char* pat, const unsigned char* name, size_t len ) {
  if (pat[0] == '*' && pat[1] == '.') {
    const char* suffix = pat + 1;   // ".domain"
    const size_t slen = strlen(suffix);
    const unsigned char* dot = (const unsigned char*)memchr(name, '.', len);
    if (dot == NULL || dot == name) return false;
    const size_t rest = len - (size_t)(dot - name);
    return (rest == slen && strncasecmp((const char*)dot, suffix, slen) == 0);
  }
  return (strlen(pat) == len && strncasecmp(pat, (const char*)name, len) == 0);
}

// Select the certificate for the name the client asked for (or keep the default one).
static int kk_tls_sni_callback( void* p, mbedtls_ssl_context* ssl, const unsigned char* name, size_t len ) {
  kk_tls_conf_t* c = (kk_tls_conf_t*)p;
  for (int i = 0; i < c->sni_count; i++) {
    if (kk_tls_name_matches(c->sni_names[i], name, len)) {
      return mbedtls_ssl_set_hs_own_cert(ssl, &c->sni_cert[i], &c->sni_key[i]);
    }
  }
  return 0;
}

// Add the certificates for server names: `sni` is `name \x01 cert \x01 key` entries separated by `\x01`.
static int kk_tls_conf_sni( kk_tls_conf_t* c, const char* sni ) {
  const char* p = sni;
  while (*p != 0) {
    const char* fields[3];
    size_t lens[3];
    for (int f = 0; f < 3; f++) {
      const char* end = strchr(p, '\x01');
      if (end == NULL) end = p + strlen(p);
      fields[f] = p; lens[f] = (size_t)(end - p);
      p = (*end == 0 ? end : end + 1);
    }
    if (c->sni_count >= KK_TLS_MAX_SNI) { snprintf(c->error, sizeof(c->error), "too many SNI certificates (at most %d)", KK_TLS_MAX_SNI); return -1; }
    const int i = c->sni_count;
    mbedtls_x509_crt_init(&c->sni_cert[i]);
    mbedtls_pk_init(&c->sni_key[i]);
    c->sni_names[i] = strndup(fields[0], lens[0]);
    c->sni_count++;
    char* cert = strndup(fields[1], lens[1]);
    int ret = mbedtls_x509_crt_parse(&c->sni_cert[i], (const unsigned char*)cert, lens[1] + 1);
    free(cert);
    if (ret != 0) { kk_tls_format_error(c->error, sizeof(c->error), "invalid SNI certificate", ret); return ret; }
    char* key = strndup(fields[2], lens[2]);
    ret = mbedtls_pk_parse_key(&c->sni_key[i], (const unsigned char*)key, lens[2] + 1, NULL, 0, mbedtls_ctr_drbg_random, &c->drbg);
    free(key);
    if (ret != 0) { kk_tls_format_error(c->error, sizeof(c->error), "invalid SNI private key", ret); return ret; }
  }
  if (c->sni_count > 0) mbedtls_ssl_conf_sni(&c->conf, &kk_tls_sni_callback, c);
  return 0;
}

// Create a server configuration from a PEM certificate chain (the server
// certificate first) and a PEM private key. If `client_ca` is not empty,
// clients are asked for a certificate signed by it; `client_cert_required`
// rejects clients without one. `alpn` is a comma separated list of protocols
// in order of preference. Check `kk_tls_server_config_error`.
kk_box_t kk_tls_server_config_new( kk_string_t cert, kk_string_t key, kk_string_t client_ca, bool client_cert_required, kk_string_t alpn, kk_string_t sni, kk_context_t* ctx ) {
  kk_tls_conf_t* c = (kk_tls_conf_t*)calloc(1, sizeof(kk_tls_conf_t));
  mbedtls_ssl_config_init(&c->conf);
  mbedtls_x509_crt_init(&c->cert);
  mbedtls_x509_crt_init(&c->client_ca);
  mbedtls_pk_init(&c->key);
  mbedtls_ctr_drbg_init(&c->drbg);
  mbedtls_entropy_init(&c->entropy);
  kk_box_t res = kk_cptr_raw_box(&kk_tls_conf_free_fun, c, ctx);
  int ret = 0;
  psa_status_t st = psa_crypto_init();
  if (st != PSA_SUCCESS) { snprintf(c->error, sizeof(c->error), "unable to initialize the crypto library (%d)", (int)st); goto done; }
  ret = mbedtls_ctr_drbg_seed(&c->drbg, mbedtls_entropy_func, &c->entropy, (const unsigned char*)"koka-tls-server", 15);
  if (ret != 0) { kk_tls_format_error(c->error, sizeof(c->error), "unable to seed the random generator", ret); goto done; }
  kk_with_string_as_qutf8_borrow(cert, ccert, ctx) {
    ret = mbedtls_x509_crt_parse(&c->cert, (const unsigned char*)ccert, strlen(ccert) + 1);
  }
  if (ret != 0) { kk_tls_format_error(c->error, sizeof(c->error), "invalid certificate", ret); goto done; }
  kk_with_string_as_qutf8_borrow(key, ckey, ctx) {
    ret = mbedtls_pk_parse_key(&c->key, (const unsigned char*)ckey, strlen(ckey) + 1, NULL, 0, mbedtls_ctr_drbg_random, &c->drbg);
  }
  if (ret != 0) { kk_tls_format_error(c->error, sizeof(c->error), "invalid private key", ret); goto done; }
  ret = mbedtls_ssl_config_defaults(&c->conf, MBEDTLS_SSL_IS_SERVER, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
  if (ret != 0) { kk_tls_format_error(c->error, sizeof(c->error), "unable to configure TLS", ret); goto done; }
  mbedtls_ssl_conf_rng(&c->conf, mbedtls_ctr_drbg_random, &c->drbg);
  ret = mbedtls_ssl_conf_own_cert(&c->conf, &c->cert, &c->key);
  if (ret != 0) { kk_tls_format_error(c->error, sizeof(c->error), "the private key does not fit the certificate", ret); goto done; }
  if (kk_string_len_borrow(client_ca, ctx) > 0) {
    kk_with_string_as_qutf8_borrow(client_ca, cca, ctx) {
      ret = mbedtls_x509_crt_parse(&c->client_ca, (const unsigned char*)cca, strlen(cca) + 1);
    }
    if (ret != 0) { kk_tls_format_error(c->error, sizeof(c->error), "invalid client CA certificate", ret); goto done; }
    mbedtls_ssl_conf_ca_chain(&c->conf, &c->client_ca, NULL);
    mbedtls_ssl_conf_authmode(&c->conf, client_cert_required ? MBEDTLS_SSL_VERIFY_REQUIRED : MBEDTLS_SSL_VERIFY_OPTIONAL);
  }
  ret = kk_tls_conf_alpn(&c->conf, alpn, &c->alpn_buf, c->alpn, ctx);
  if (ret != 0) { kk_tls_format_error(c->error, sizeof(c->error), "invalid ALPN protocols", ret); goto done; }
  kk_with_string_as_qutf8_borrow(sni, csni, ctx) {
    ret = kk_tls_conf_sni(c, csni);
  }
  if (ret != 0) goto done;
done:
  kk_string_drop(sni, ctx);
  kk_string_drop(cert, ctx);
  kk_string_drop(key, ctx);
  kk_string_drop(client_ca, ctx);
  kk_string_drop(alpn, ctx);
  return res;
}

kk_string_t kk_tls_server_config_error( kk_box_t bc, kk_context_t* ctx ) {
  kk_tls_conf_t* c = (kk_tls_conf_t*)kk_cptr_raw_unbox_borrowed(bc, ctx);
  kk_string_t s = kk_string_alloc_from_utf8(c->error, ctx);
  kk_box_drop(bc, ctx);
  return s;
}

// Create a TLS server engine for one connection. Check `kk_tls_error` for failures.
kk_box_t kk_tls_new_server( kk_box_t bc, kk_context_t* ctx ) {
  kk_box_t res;
  kk_tls_t* t = kk_tls_alloc(&res, ctx);
  kk_tls_conf_t* c = (kk_tls_conf_t*)kk_cptr_raw_unbox_borrowed(bc, ctx);
  t->sconf = bc;   // takes ownership
  t->has_sconf = true;
  if (c->error[0] != 0) { snprintf(t->error, sizeof(t->error), "%s", c->error); return res; }
  int ret = mbedtls_ssl_setup(&t->ssl, &c->conf);
  if (ret != 0) { kk_tls_set_error(t, "unable to set up TLS", ret); return res; }
  mbedtls_ssl_set_bio(&t->ssl, t, &kk_tls_bio_send, &kk_tls_bio_recv, NULL);
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
  if (ret == 0 && t->has_sconf && mbedtls_ssl_get_peer_cert(&t->ssl) != NULL && mbedtls_ssl_get_verify_result(&t->ssl) != 0) {
    // a server with optional client certificates: a certificate that is presented must be valid
    char vinfo[160];
    mbedtls_x509_crt_verify_info(vinfo, sizeof(vinfo), "", mbedtls_ssl_get_verify_result(&t->ssl));
    char* nl = strchr(vinfo, '\n');
    if (nl != NULL) *nl = 0;
    snprintf(t->error, sizeof(t->error), "client certificate verification failed: %s", vinfo);
    status = -1;
  }
  else if (ret == 0) status = 0;
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

// The negotiated ALPN protocol ("" if none).
kk_string_t kk_tls_alpn( kk_box_t bt, kk_context_t* ctx ) {
  kk_tls_t* t = kk_tls_unbox(bt, ctx);
  const char* proto = mbedtls_ssl_get_alpn_protocol(&t->ssl);
  kk_string_t s = kk_string_alloc_from_utf8(proto == NULL ? "" : proto, ctx);
  kk_box_drop(bt, ctx);
  return s;
}

// The subject of the verified peer certificate, for example "CN=example.com" ("" if none).
kk_string_t kk_tls_peer_subject( kk_box_t bt, kk_context_t* ctx ) {
  kk_tls_t* t = kk_tls_unbox(bt, ctx);
  char buf[512];
  buf[0] = 0;
  const mbedtls_x509_crt* crt = mbedtls_ssl_get_peer_cert(&t->ssl);
  if (crt != NULL && mbedtls_ssl_get_verify_result(&t->ssl) == 0) {
    if (mbedtls_x509_dn_gets(buf, sizeof(buf), &crt->subject) < 0) buf[0] = 0;
  }
  kk_string_t s = kk_string_alloc_from_utf8(buf, ctx);
  kk_box_drop(bt, ctx);
  return s;
}
