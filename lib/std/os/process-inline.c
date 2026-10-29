/*---------------------------------------------------------------------------
  Copyright 2020-2021, Microsoft Research, Daan Leijen.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

static kk_std_core_exn__error kk_os_run_command_error( kk_string_t cmd, kk_context_t* ctx ) {
  kk_string_t output;
  const int err = kk_os_run_command(cmd,&output,ctx);
  if (err != 0) return kk_error_from_errno(err,ctx);
           else return kk_error_ok(kk_string_box(output),ctx);
}

static kk_integer_t kk_os_run_system_prim( kk_string_t cmd, kk_context_t* ctx ) {
  const int exitcode = kk_os_run_system(cmd,ctx);
  return kk_integer_from_int(exitcode,ctx);
}

/*---------------------------------------------------------------------------
  Spawning processes with arguments, capturing stdout and stderr.
---------------------------------------------------------------------------*/
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#if !defined(_WIN32)
#include <spawn.h>
#include <poll.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/wait.h>
extern char** environ;

typedef struct kk_os_obuf_s {
  uint8_t* buf;
  kk_ssize_t len;
  kk_ssize_t cap;
} kk_os_obuf_t;

static void kk_os_obuf_add( kk_os_obuf_t* b, const uint8_t* p, kk_ssize_t n, kk_context_t* ctx ) {
  if (b->len + n > b->cap) {
    kk_ssize_t newcap = (b->cap == 0 ? 4096 : b->cap);
    while (newcap < b->len + n) newcap *= 2;
    b->buf = (uint8_t*)(b->buf == NULL ? kk_malloc(newcap,ctx) : kk_realloc(b->buf,newcap,ctx));
    b->cap = newcap;
  }
  memcpy(b->buf + b->len, p, (size_t)n);
  b->len += n;
}

static kk_bytes_t kk_os_obuf_to_bytes( kk_os_obuf_t* b, kk_context_t* ctx ) {
  kk_bytes_t res = kk_bytes_alloc_dupn(b->len, b->buf, ctx);
  if (b->buf != NULL) kk_free(b->buf,ctx);
  b->buf = NULL;
  return res;
}

// Convert a (borrowed) vector of strings into a NULL terminated array of C strings
static char** kk_os_cstrings( kk_vector_t v, kk_context_t* ctx ) {
  kk_ssize_t n;
  kk_box_t* xs = kk_vector_buf_borrow(v, &n, ctx);
  char** res = (char**)kk_malloc((n + 1)*kk_ssizeof(char*), ctx);
  for (kk_ssize_t i = 0; i < n; i++) {
    kk_ssize_t len;
    const char* s = kk_string_cbuf_borrow(kk_string_unbox(xs[i]), &len, ctx);
    res[i] = (char*)kk_malloc(len + 1, ctx);
    memcpy(res[i], s, (size_t)len + 1);
  }
  res[n] = NULL;
  return res;
}

static void kk_os_free_cstrings( char** xs, kk_context_t* ctx ) {
  if (xs == NULL) return;
  for (char** p = xs; *p != NULL; p++) kk_free(*p, ctx);
  kk_free(xs, ctx);
}
#endif

// Run `cmd` with arguments `args` (the vector does not include the program name),
// feeding `input` on stdin, in directory `cwd` (if not empty), with environment
// `env` (as `name=value` strings; inherit the current environment if empty).
// Returns `(exit-code, stdout, stderr)`.
static kk_std_core_exn__error kk_os_spawn_prim( kk_string_t cmd, kk_vector_t args, kk_bytes_t input, kk_string_t cwd, kk_vector_t env, kk_context_t* ctx ) {
  #if defined(_WIN32)
  kk_string_drop(cmd,ctx); kk_vector_drop(args,ctx); kk_bytes_drop(input,ctx); kk_string_drop(cwd,ctx); kk_vector_drop(env,ctx);
  return kk_error_from_errno(ENOSYS,ctx);
  #else
  int err = 0;
  int code = -1;
  bool have_output = false;
  kk_bytes_t bout = kk_bytes_empty();
  kk_bytes_t berr = kk_bytes_empty();
  // argv = [cmd] ++ args
  kk_ssize_t nargs;
  kk_box_t* xargs = kk_vector_buf_borrow(args, &nargs, ctx);
  char** argv = (char**)kk_malloc((nargs + 2)*kk_ssizeof(char*), ctx);
  {
    kk_ssize_t len;
    const char* s = kk_string_cbuf_borrow(cmd, &len, ctx);
    argv[0] = (char*)kk_malloc(len + 1, ctx);
    memcpy(argv[0], s, (size_t)len + 1);
  }
  for (kk_ssize_t i = 0; i < nargs; i++) {
    kk_ssize_t len;
    const char* s = kk_string_cbuf_borrow(kk_string_unbox(xargs[i]), &len, ctx);
    argv[i+1] = (char*)kk_malloc(len + 1, ctx);
    memcpy(argv[i+1], s, (size_t)len + 1);
  }
  argv[nargs+1] = NULL;
  char** envp = (kk_vector_len_borrow(env,ctx) > 0 ? kk_os_cstrings(env, ctx) : NULL);

  int pin[2] = { -1, -1 }, pout[2] = { -1, -1 }, perr[2] = { -1, -1 };
  if (pipe(pin) != 0 || pipe(pout) != 0 || pipe(perr) != 0) { err = errno; goto cleanup; }

  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, pin[0], 0);
  posix_spawn_file_actions_adddup2(&fa, pout[1], 1);
  posix_spawn_file_actions_adddup2(&fa, perr[1], 2);
  posix_spawn_file_actions_addclose(&fa, pin[0]);  posix_spawn_file_actions_addclose(&fa, pin[1]);
  posix_spawn_file_actions_addclose(&fa, pout[0]); posix_spawn_file_actions_addclose(&fa, pout[1]);
  posix_spawn_file_actions_addclose(&fa, perr[0]); posix_spawn_file_actions_addclose(&fa, perr[1]);
  kk_ssize_t cwdlen;
  const char* ccwd = kk_string_cbuf_borrow(cwd, &cwdlen, ctx);
  if (cwdlen > 0) {
    #if defined(__APPLE__) || (defined(__GLIBC__) && ((__GLIBC__ > 2) || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 29)))
    posix_spawn_file_actions_addchdir_np(&fa, ccwd);
    #else
    posix_spawn_file_actions_destroy(&fa);
    err = ENOSYS;
    goto cleanup;
    #endif
  }
  pid_t pid;
  const int serr = posix_spawnp(&pid, argv[0], &fa, NULL, argv, (envp != NULL ? envp : environ));
  posix_spawn_file_actions_destroy(&fa);
  if (serr != 0) { err = serr; goto cleanup; }
  close(pin[0]);  pin[0] = -1;
  close(pout[1]); pout[1] = -1;
  close(perr[1]); perr[1] = -1;

  // ignore SIGPIPE while writing to the child's stdin
  struct sigaction sa_ignore, sa_old;
  memset(&sa_ignore, 0, sizeof(sa_ignore));
  sa_ignore.sa_handler = SIG_IGN;
  sigaction(SIGPIPE, &sa_ignore, &sa_old);

  kk_ssize_t inlen;
  const uint8_t* inbuf = kk_bytes_buf_borrow(input, &inlen, ctx);
  kk_ssize_t inpos = 0;
  if (inlen == 0) { close(pin[1]); pin[1] = -1; }
  else { fcntl(pin[1], F_SETFL, fcntl(pin[1], F_GETFL) | O_NONBLOCK); }

  kk_os_obuf_t out = { NULL, 0, 0 };
  kk_os_obuf_t errb = { NULL, 0, 0 };
  uint8_t chunk[16*1024];
  while (pout[0] >= 0 || perr[0] >= 0 || pin[1] >= 0) {
    struct pollfd fds[3];
    int nfds = 0;
    int iout = -1, ierr = -1, iin = -1;
    if (pout[0] >= 0) { fds[nfds].fd = pout[0]; fds[nfds].events = POLLIN; iout = nfds++; }
    if (perr[0] >= 0) { fds[nfds].fd = perr[0]; fds[nfds].events = POLLIN; ierr = nfds++; }
    if (pin[1] >= 0)  { fds[nfds].fd = pin[1];  fds[nfds].events = POLLOUT; iin = nfds++; }
    if (poll(fds, (nfds_t)nfds, -1) < 0) {
      if (errno == EINTR) continue;
      err = errno;
      break;
    }
    if (iout >= 0 && (fds[iout].revents & (POLLIN|POLLHUP|POLLERR))) {
      ssize_t n = read(pout[0], chunk, sizeof(chunk));
      if (n > 0) kk_os_obuf_add(&out, chunk, (kk_ssize_t)n, ctx);
      else if (n == 0 || errno != EINTR) { close(pout[0]); pout[0] = -1; }
    }
    if (ierr >= 0 && (fds[ierr].revents & (POLLIN|POLLHUP|POLLERR))) {
      ssize_t n = read(perr[0], chunk, sizeof(chunk));
      if (n > 0) kk_os_obuf_add(&errb, chunk, (kk_ssize_t)n, ctx);
      else if (n == 0 || errno != EINTR) { close(perr[0]); perr[0] = -1; }
    }
    if (iin >= 0 && (fds[iin].revents & (POLLOUT|POLLHUP|POLLERR))) {
      ssize_t n = write(pin[1], inbuf + inpos, (size_t)(inlen - inpos));
      if (n > 0) inpos += (kk_ssize_t)n;
      if ((n < 0 && errno != EAGAIN && errno != EINTR) || inpos >= inlen) { close(pin[1]); pin[1] = -1; }
    }
  }
  sigaction(SIGPIPE, &sa_old, NULL);

  int status = 0;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) { if (err == 0) err = errno; break; }
  }
  bout = kk_os_obuf_to_bytes(&out, ctx);
  berr = kk_os_obuf_to_bytes(&errb, ctx);
  have_output = true;
  code = (WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1));

cleanup:
  for (int i = 0; i < 2; i++) {
    if (pin[i] >= 0) close(pin[i]);
    if (pout[i] >= 0) close(pout[i]);
    if (perr[i] >= 0) close(perr[i]);
  }
  kk_os_free_cstrings(argv, ctx);
  kk_os_free_cstrings(envp, ctx);
  kk_string_drop(cmd,ctx);
  kk_vector_drop(args,ctx);
  kk_bytes_drop(input,ctx);
  kk_string_drop(cwd,ctx);
  kk_vector_drop(env,ctx);
  if (err != 0 || !have_output) {
    kk_bytes_drop(bout,ctx);
    kk_bytes_drop(berr,ctx);
    return kk_error_from_errno(err != 0 ? err : EIO,ctx);
  }
  kk_std_core_types__tuple3 res = kk_std_core_types__new_Tuple3(
    kk_integer_box(kk_integer_from_int(code,ctx),ctx), kk_bytes_box(bout), kk_bytes_box(berr), ctx);
  return kk_error_ok(kk_std_core_types__tuple3_box(res,ctx),ctx);
  #endif
}
