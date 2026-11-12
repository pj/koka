/*---------------------------------------------------------------------------
  Copying updates of the child vectors of std/data/hashmap nodes.
---------------------------------------------------------------------------*/

// a copy of `v` with `x` at `i` (in place if `v` is unique)
static inline kk_vector_t kk_hamt_replace(kk_vector_t v, kk_ssize_t i, kk_box_t x, kk_context_t* ctx) {
  kk_ssize_t len;
  kk_box_t* src = kk_vector_buf_borrow(v, &len, ctx);
  if (kk_datatype_is_unique(v, ctx)) {
    kk_box_drop(src[i], ctx);
    src[i] = x;
    return v;
  }
  kk_box_t* dest;
  kk_vector_t w = kk_vector_alloc_uninit(len, &dest, ctx);
  for (kk_ssize_t j = 0; j < len; j++) {
    dest[j] = (j == i ? x : kk_box_dup(src[j], ctx));
  }
  kk_vector_drop(v, ctx);
  return w;
}

// a copy of `v` with `x` inserted before position `i`
static inline kk_vector_t kk_hamt_insert(kk_vector_t v, kk_ssize_t i, kk_box_t x, kk_context_t* ctx) {
  kk_ssize_t len;
  kk_box_t* src = kk_vector_buf_borrow(v, &len, ctx);
  kk_box_t* dest;
  kk_vector_t w = kk_vector_alloc_uninit(len + 1, &dest, ctx);
  for (kk_ssize_t j = 0; j < i; j++)   { dest[j] = kk_box_dup(src[j], ctx); }
  dest[i] = x;
  for (kk_ssize_t j = i; j < len; j++) { dest[j+1] = kk_box_dup(src[j], ctx); }
  kk_vector_drop(v, ctx);
  return w;
}

// a copy of `v` without the element at position `i`
static inline kk_vector_t kk_hamt_remove(kk_vector_t v, kk_ssize_t i, kk_context_t* ctx) {
  kk_ssize_t len;
  kk_box_t* src = kk_vector_buf_borrow(v, &len, ctx);
  kk_box_t* dest;
  kk_vector_t w = kk_vector_alloc_uninit(len - 1, &dest, ctx);
  for (kk_ssize_t j = 0; j < i; j++)       { dest[j] = kk_box_dup(src[j], ctx); }
  for (kk_ssize_t j = i + 1; j < len; j++) { dest[j-1] = kk_box_dup(src[j], ctx); }
  kk_vector_drop(v, ctx);
  return w;
}
