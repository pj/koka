/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/*---------------------------------------------------------------------------
  Binary files, metadata, and file system manipulation.
  POSIX implementation, with Windows (MSVCRT) equivalents; on Windows
  `set-permissions` can only make files read-only or writable, and there
  are no symbolic links.
---------------------------------------------------------------------------*/
#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>
#if !defined(_WIN32)
#include <unistd.h>
#include <stdlib.h>
#else
#include <io.h>
#include <direct.h>
#include <fcntl.h>
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
  // only the owner's write permission can be set (as the read-only attribute)
  const int res = _chmod(kk_string_cbuf_borrow(path,NULL,ctx), ((m & 0200) != 0 ? (_S_IREAD | _S_IWRITE) : _S_IREAD));
  const int err = (res != 0 ? errno : 0);
  #else
  const int res = chmod(kk_string_cbuf_borrow(path,NULL,ctx), (mode_t)m);
  const int err = (res != 0 ? errno : 0);
  #endif
  kk_string_drop(path,ctx);
  return kk_os_unit_result(err,ctx);
}

#if defined(_WIN32)
// Create a file (or directory) named `<prefix>` + 6 random characters that did not exist yet.
static kk_std_core_exn__error kk_os_win_unique( kk_string_t prefix, bool is_dir, kk_context_t* ctx ) {
  static const char letters[] = "abcdefghijklmnopqrstuvwxyz0123456789";
  kk_ssize_t plen;
  const char* p = kk_string_cbuf_borrow(prefix,&plen,ctx);
  char* name = (char*)kk_malloc(plen + 7,ctx);
  memcpy(name, p, (size_t)plen);
  name[plen + 6] = 0;
  kk_string_drop(prefix,ctx);
  int err = EEXIST;
  for (int attempt = 0; attempt < 100 && err == EEXIST; attempt++) {
    for (int i = 0; i < 6; i++) name[plen + i] = letters[kk_srandom_uint32(ctx) % 36];
    if (is_dir) {
      err = (_mkdir(name) != 0 ? errno : 0);
    }
    else {
      const int fd = _open(name, _O_CREAT | _O_EXCL | _O_RDWR | _O_BINARY, _S_IREAD | _S_IWRITE);
      err = (fd < 0 ? errno : 0);
      if (fd >= 0) _close(fd);
    }
  }
  if (err != 0) {
    kk_free(name,ctx);
    return kk_error_from_errno(err,ctx);
  }
  kk_string_t s = kk_string_alloc_from_utf8(name,ctx);
  kk_free(name,ctx);
  return kk_error_ok(kk_string_box(s),ctx);
}
#endif

// Create a unique temporary file `<dir>/<prefix>XXXXXX` and return its path
static kk_std_core_exn__error kk_os_temp_file_prim( kk_string_t prefix, kk_context_t* ctx ) {
  #if defined(_WIN32)
  return kk_os_win_unique(prefix, false, ctx);
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
  return kk_os_win_unique(prefix, true, ctx);
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

/*---------------------------------------------------------------------------
  File handles: a boxed C pointer to the file descriptor. Closing sets the
  descriptor to -1 (so closing twice is harmless), and a handle that is no
  longer referenced is closed by its finalizer.
---------------------------------------------------------------------------*/
#if defined(_WIN32)
// Windows (MSVCRT): binary mode, and handles are not inherited by child processes
#define kk_fd_open(path,flags)   _open(path, (flags) | _O_BINARY | _O_NOINHERIT, _S_IREAD | _S_IWRITE)
#define kk_fd_read(fd,buf,n)     _read(fd, buf, (unsigned int)(n))
#define kk_fd_write(fd,buf,n)    _write(fd, buf, (unsigned int)(n))
#define kk_fd_close(fd)          _close(fd)
typedef int kk_fd_ssize_t;
#else
#include <fcntl.h>
#ifdef O_CLOEXEC
#define kk_fd_open(path,flags)   open(path, (flags) | O_CLOEXEC, 0666)
#else
#define kk_fd_open(path,flags)   open(path, flags, 0666)
#endif
#define kk_fd_read(fd,buf,n)     read(fd, buf, (size_t)(n))
#define kk_fd_write(fd,buf,n)    write(fd, buf, (size_t)(n))
#define kk_fd_close(fd)          close(fd)
typedef ssize_t kk_fd_ssize_t;
#endif

static void kk_os_fd_free( void* p, kk_block_t* block, kk_context_t* ctx ) {
  kk_unused(block);
  int* pfd = (int*)p;
  if (*pfd >= 0) kk_fd_close(*pfd);
  kk_free(pfd,ctx);
}

static int kk_os_fd_of( kk_box_t h, kk_context_t* ctx ) {
  int* pfd = (int*)kk_cptr_raw_unbox_borrowed(h,ctx);
  return (pfd == NULL ? -1 : *pfd);
}

// mode 0: read, 1: write (create and truncate), 2: append (create)
static kk_std_core_exn__error kk_os_fd_open( kk_string_t path, kk_integer_t mode, kk_context_t* ctx ) {
  const int m = kk_integer_clamp32(mode,ctx);
  const int flags = (m == 0 ? O_RDONLY : (m == 1 ? (O_WRONLY | O_CREAT | O_TRUNC) : (O_WRONLY | O_CREAT | O_APPEND)));
  int fd;
  do { fd = kk_fd_open(kk_string_cbuf_borrow(path,NULL,ctx), flags); } while (fd < 0 && errno == EINTR);
  const int err = errno;
  kk_string_drop(path,ctx);
  if (fd < 0) return kk_error_from_errno(err,ctx);
  int* pfd = (int*)kk_malloc(sizeof(int),ctx);
  *pfd = fd;
  return kk_error_ok(kk_cptr_raw_box(&kk_os_fd_free, pfd, ctx),ctx);
}

// Read at most `max` bytes; an empty result means the end of the file.
static kk_std_core_exn__error kk_os_fd_read( kk_box_t h, kk_integer_t max, kk_context_t* ctx ) {
  const int fd = kk_os_fd_of(h,ctx);
  kk_box_drop(h,ctx);
  kk_ssize_t n = kk_integer_clamp_ssize_t(max,ctx);
  if (n <= 0) n = 64*1024;
  if (fd < 0) return kk_error_from_errno(EBADF,ctx);
  uint8_t* buf;
  kk_bytes_t b = kk_bytes_alloc_buf(n, &buf, ctx);
  kk_fd_ssize_t res;
  do { res = kk_fd_read(fd, buf, n); } while (res < 0 && errno == EINTR);
  if (res < 0) {
    const int err = errno;
    kk_bytes_drop(b,ctx);
    return kk_error_from_errno(err,ctx);
  }
  if (res == 0) {
    kk_bytes_drop(b,ctx);
    return kk_error_ok(kk_bytes_box(kk_bytes_empty()),ctx);
  }
  b = kk_bytes_adjust_length(b, (kk_ssize_t)res, ctx);
  return kk_error_ok(kk_bytes_box(b),ctx);
}

// Write all the bytes.
static kk_std_core_exn__error kk_os_fd_write( kk_box_t h, kk_bytes_t content, kk_context_t* ctx ) {
  const int fd = kk_os_fd_of(h,ctx);
  kk_box_drop(h,ctx);
  if (fd < 0) {
    kk_bytes_drop(content,ctx);
    return kk_error_from_errno(EBADF,ctx);
  }
  if (fd == 1) fflush(stdout);   // keep the order with the console output
  kk_ssize_t len;
  const uint8_t* p = kk_bytes_buf_borrow(content,&len,ctx);
  int err = 0;
  while (len > 0) {
    const kk_fd_ssize_t res = kk_fd_write(fd, p, len);
    if (res < 0) {
      if (errno == EINTR) continue;
      err = errno;
      break;
    }
    p += res;
    len -= (kk_ssize_t)res;
  }
  kk_bytes_drop(content,ctx);
  return kk_os_unit_result(err,ctx);
}

static kk_std_core_exn__error kk_os_fd_close( kk_box_t h, kk_context_t* ctx ) {
  int* pfd = (int*)kk_cptr_raw_unbox_borrowed(h,ctx);
  int err = 0;
  if (pfd != NULL && *pfd >= 0) {
    const int fd = *pfd;
    *pfd = -1;
    if (kk_fd_close(fd) != 0 && errno != EINTR) err = errno;
  }
  kk_box_drop(h,ctx);
  return kk_os_unit_result(err,ctx);
}
