/*---------------------------------------------------------------------------
  Hashing primitives (MurmurHash3, 32-bit) for std/data/hash.
---------------------------------------------------------------------------*/

static inline uint32_t kk_hash_rotl32(uint32_t x, int r) {
  return (x << r) | (x >> (32 - r));
}

static inline uint32_t kk_hash_scramble32(uint32_t k) {
  k *= 0xcc9e2d51u;
  k = kk_hash_rotl32(k, 15);
  k *= 0x1b873593u;
  return k;
}

static inline int32_t kk_hash_mix32(int32_t h0, int32_t k0) {
  uint32_t h = (uint32_t)h0 ^ kk_hash_scramble32((uint32_t)k0);
  h = kk_hash_rotl32(h, 13);
  h = h*5u + 0xe6546b64u;
  return (int32_t)h;
}

static inline int32_t kk_hash_fmix32(int32_t h0) {
  uint32_t h = (uint32_t)h0;
  h ^= h >> 16;
  h *= 0x85ebca6bu;
  h ^= h >> 13;
  h *= 0xc2b2ae35u;
  h ^= h >> 16;
  return (int32_t)h;
}

// MurmurHash3_x86_32 over the UTF-8 bytes of a (borrowed) string
static inline int32_t kk_hash_string32(kk_string_t s, int32_t seed, kk_context_t* ctx) {
  kk_ssize_t len;
  const uint8_t* p = kk_string_buf_borrow(s, &len, ctx);
  int32_t h = seed;
  kk_ssize_t i = 0;
  for (; i + 4 <= len; i += 4) {
    uint32_t k = (uint32_t)p[i] | ((uint32_t)p[i+1] << 8) | ((uint32_t)p[i+2] << 16) | ((uint32_t)p[i+3] << 24);
    h = kk_hash_mix32(h, (int32_t)k);
  }
  const kk_ssize_t rem = len & 3;
  if (rem > 0) {
    uint32_t k = 0;
    if (rem >= 3) k ^= (uint32_t)p[i+2] << 16;
    if (rem >= 2) k ^= (uint32_t)p[i+1] << 8;
    k ^= (uint32_t)p[i];
    h = (int32_t)((uint32_t)h ^ kk_hash_scramble32(k));
  }
  h = (int32_t)((uint32_t)h ^ (uint32_t)len);
  return kk_hash_fmix32(h);
}
