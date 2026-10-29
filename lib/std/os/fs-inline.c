/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/*---------------------------------------------------------------------------
  Binary files, metadata, and file system manipulation.
  POSIX implementation; on Windows most operations return ENOSYS.
---------------------------------------------------------------------------*/
#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>
#if !defined(_WIN32)
#include <unistd.h>
#include <stdlib.h>
#endif

static kk_std_core_exn__error kk_os_unit_result( int err, kk_context_t* ctx ) {
  if (err != 0) return kk_error_from_errno(err,ctx);
           else return kk_error_ok(kk_unit_box(kk_Unit),ctx);
}

static kk_std_core_exn__error kk_os_read_file_bytes( kk_string_t path, kk_context_t* ctx ) {
  FILE* f = fopen(kk_string_cbuf_borrow(path,NULL,ctx), "rb");
  kk_string_drop(path,ctx);
  if (f == NULL) return kk_error_from_errno(errno,ctx);
  kk_ssize_t cap = 64*1024;
  kk_ssize_t len = 0;
  uint8_t* buf = (uint8_t*)kk_malloc(cap,ctx);
  size_t n;
  while ((n = fread(buf + len, 1, (size_t)(cap - len), f)) > 0) {
    len += (kk_ssize_t)n;
    if (len == cap) {
      cap *= 2;
      buf = (uint8_t*)kk_realloc(buf,cap,ctx);
    }
  }
  const int err = (ferror(f) ? EIO : 0);
  fclose(f);
  if (err != 0) {
    kk_free(buf,ctx);
    return kk_error_from_errno(err,ctx);
  }
  kk_bytes_t b = kk_bytes_alloc_dupn(len, buf, ctx);
  kk_free(buf,ctx);
  return kk_error_ok(kk_bytes_box(b),ctx);
}

static kk_std_core_exn__error kk_os_write_file_bytes( kk_string_t path, kk_bytes_t content, bool append, kk_context_t* ctx ) {
  FILE* f = fopen(kk_string_cbuf_borrow(path,NULL,ctx), (append ? "ab" : "wb"));
  kk_string_drop(path,ctx);
  if (f == NULL) {
    const int err = errno;
    kk_bytes_drop(content,ctx);
    return kk_error_from_errno(err,ctx);
  }
  kk_ssize_t len;
  const uint8_t* p = kk_bytes_buf_borrow(content,&len,ctx);
  int err = 0;
  if (len > 0 && fwrite(p, 1, (size_t)len, f) != (size_t)len) err = (errno != 0 ? errno : EIO);
  if (fclose(f) != 0 && err == 0) err = errno;
  kk_bytes_drop(content,ctx);
  return kk_os_unit_result(err,ctx);
}

// Returns a vector of integers: [kind, size, mtime-seconds, mtime-nanoseconds, mode]
// where kind is 0: file, 1: directory, 2: symbolic link, 3: other.
static kk_std_core_exn__error kk_os_stat_prim( kk_string_t path, bool follow, kk_context_t* ctx ) {
  struct stat st;
  const char* cpath = kk_string_cbuf_borrow(path,NULL,ctx);
  #if defined(_WIN32)
  const int res = stat(cpath,&st);
  #else
  const int res = (follow ? stat(cpath,&st) : lstat(cpath,&st));
  #endif
  const int err = errno;
  kk_string_drop(path,ctx);
  if (res != 0) return kk_error_from_errno(err,ctx);
  int kind = 3;
  if (S_ISREG(st.st_mode)) kind = 0;
  else if (S_ISDIR(st.st_mode)) kind = 1;
  #if !defined(_WIN32)
  else if (S_ISLNK(st.st_mode)) kind = 2;
  #endif
  int64_t msecs = (int64_t)st.st_mtime;
  int64_t mnsecs = 0;
  #if defined(__APPLE__)
  msecs = (int64_t)st.st_mtimespec.tv_sec;
  mnsecs = (int64_t)st.st_mtimespec.tv_nsec;
  #elif defined(__linux__)
  msecs = (int64_t)st.st_mtim.tv_sec;
  mnsecs = (int64_t)st.st_mtim.tv_nsec;
  #endif
  kk_box_t* buf;
  kk_vector_t v = kk_vector_alloc_uninit(5, &buf, ctx);
  buf[0] = kk_integer_box(kk_integer_from_int(kind,ctx),ctx);
  buf[1] = kk_integer_box(kk_integer_from_int64((int64_t)st.st_size,ctx),ctx);
  buf[2] = kk_integer_box(kk_integer_from_int64(msecs,ctx),ctx);
  buf[3] = kk_integer_box(kk_integer_from_int64(mnsecs,ctx),ctx);
  buf[4] = kk_integer_box(kk_integer_from_int((int)(st.st_mode & 07777),ctx),ctx);
  return kk_error_ok(kk_vector_box(v,ctx),ctx);
}

static kk_std_core_exn__error kk_os_remove_file_prim( kk_string_t path, kk_context_t* ctx ) {
  const int res = remove(kk_string_cbuf_borrow(path,NULL,ctx));
  const int err = (res != 0 ? errno : 0);
  kk_string_drop(path,ctx);
  return kk_os_unit_result(err,ctx);
}

static kk_std_core_exn__error kk_os_rename_prim( kk_string_t from, kk_string_t to, kk_context_t* ctx ) {
  const int res = rename(kk_string_cbuf_borrow(from,NULL,ctx), kk_string_cbuf_borrow(to,NULL,ctx));
  const int err = (res != 0 ? errno : 0);
  kk_string_drop(from,ctx);
  kk_string_drop(to,ctx);
  return kk_os_unit_result(err,ctx);
}

static kk_std_core_exn__error kk_os_chmod_prim( kk_string_t path, kk_integer_t mode, kk_context_t* ctx ) {
  const int m = kk_integer_clamp32(mode,ctx);
  #if defined(_WIN32)
  const int err = ENOSYS;
  #else
  const int res = chmod(kk_string_cbuf_borrow(path,NULL,ctx), (mode_t)m);
  const int err = (res != 0 ? errno : 0);
  #endif
  kk_string_drop(path,ctx);
  return kk_os_unit_result(err,ctx);
}

// Create a unique temporary file `<dir>/<prefix>XXXXXX` and return its path
static kk_std_core_exn__error kk_os_temp_file_prim( kk_string_t prefix, kk_context_t* ctx ) {
  #if defined(_WIN32)
  kk_string_drop(prefix,ctx);
  return kk_error_from_errno(ENOSYS,ctx);
  #else
  kk_ssize_t plen;
  const char* p = kk_string_cbuf_borrow(prefix,&plen,ctx);
  char* tmpl = (char*)kk_malloc(plen + 7,ctx);
  memcpy(tmpl, p, (size_t)plen);
  memcpy(tmpl + plen, "XXXXXX", 7);
  kk_string_drop(prefix,ctx);
  const int fd = mkstemp(tmpl);
  if (fd < 0) {
    const int err = errno;
    kk_free(tmpl,ctx);
    return kk_error_from_errno(err,ctx);
  }
  close(fd);
  kk_string_t s = kk_string_alloc_from_utf8(tmpl,ctx);
  kk_free(tmpl,ctx);
  return kk_error_ok(kk_string_box(s),ctx);
  #endif
}

/*---------------------------------------------------------------------------
  Creating, removing and changing directories.
---------------------------------------------------------------------------*/


static kk_std_core_exn__error kk_os_create_dir_prim( kk_string_t path, kk_context_t* ctx ) {
  #if defined(_WIN32)
  const int res = _mkdir(kk_string_cbuf_borrow(path,NULL,ctx));
  #else
  const int res = mkdir(kk_string_cbuf_borrow(path,NULL,ctx), 0777);
  #endif
  const int err = (res != 0 ? errno : 0);
  kk_string_drop(path,ctx);
  return kk_os_unit_result(err,ctx);
}

static kk_std_core_exn__error kk_os_remove_dir_prim( kk_string_t path, kk_context_t* ctx ) {
  #if defined(_WIN32)
  const int res = _rmdir(kk_string_cbuf_borrow(path,NULL,ctx));
  #else
  const int res = rmdir(kk_string_cbuf_borrow(path,NULL,ctx));
  #endif
  const int err = (res != 0 ? errno : 0);
  kk_string_drop(path,ctx);
  return kk_os_unit_result(err,ctx);
}

static kk_std_core_exn__error kk_os_set_cwd_prim( kk_string_t path, kk_context_t* ctx ) {
  #if defined(_WIN32)
  const int res = _chdir(kk_string_cbuf_borrow(path,NULL,ctx));
  #else
  const int res = chdir(kk_string_cbuf_borrow(path,NULL,ctx));
  #endif
  const int err = (res != 0 ? errno : 0);
  kk_string_drop(path,ctx);
  return kk_os_unit_result(err,ctx);
}

// Create a unique temporary directory `<prefix>XXXXXX` and return its path
static kk_std_core_exn__error kk_os_temp_dir_prim( kk_string_t prefix, kk_context_t* ctx ) {
  #if defined(_WIN32)
  kk_string_drop(prefix,ctx);
  return kk_error_from_errno(ENOSYS,ctx);
  #else
  kk_ssize_t plen;
  const char* p = kk_string_cbuf_borrow(prefix,&plen,ctx);
  char* tmpl = (char*)kk_malloc(plen + 7,ctx);
  memcpy(tmpl, p, (size_t)plen);
  memcpy(tmpl + plen, "XXXXXX", 7);
  kk_string_drop(prefix,ctx);
  if (mkdtemp(tmpl) == NULL) {
    const int err = errno;
    kk_free(tmpl,ctx);
    return kk_error_from_errno(err,ctx);
  }
  kk_string_t s = kk_string_alloc_from_utf8(tmpl,ctx);
  kk_free(tmpl,ctx);
  return kk_error_ok(kk_string_box(s),ctx);
  #endif
}
