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

#if defined(_WIN32)
/*---------------------------------------------------------------------------
  Windows: CreateProcess with pipes; a thread writes stdin and another one
  reads stderr while stdout is read here (so no pipe can fill up and block).
---------------------------------------------------------------------------*/
#include <windows.h>

typedef struct kk_os_win_buf_s { char* buf; size_t len; size_t cap; } kk_os_win_buf_t;

static void kk_os_win_add( kk_os_win_buf_t* b, const char* p, size_t n ) {
  if (b->len + n + 1 > b->cap) {
    size_t cap = (b->cap == 0 ? 256 : b->cap);
    while (b->len + n + 1 > cap) cap *= 2;
    b->buf = (char*)realloc(b->buf, cap);
    b->cap = cap;
  }
  memcpy(b->buf + b->len, p, n);
  b->len += n;
  b->buf[b->len] = 0;
}

static void kk_os_win_addc( kk_os_win_buf_t* b, char c ) {
  kk_os_win_add(b, &c, 1);
}

// Quote an argument for the C runtime's command line parsing.
static void kk_os_win_quote( kk_os_win_buf_t* b, const char* arg ) {
  if (arg[0] != 0 && strpbrk(arg, " \t\n\v\"") == NULL) { kk_os_win_add(b, arg, strlen(arg)); return; }
  kk_os_win_addc(b, '"');
  for (const char* p = arg; ; p++) {
    size_t slashes = 0;
    while (*p == '\\') { slashes++; p++; }
    if (*p == 0) { for (size_t i = 0; i < 2*slashes; i++) kk_os_win_addc(b, '\\'); break; }
    else if (*p == '"') { for (size_t i = 0; i < 2*slashes + 1; i++) kk_os_win_addc(b, '\\'); kk_os_win_addc(b, '"'); }
    else { for (size_t i = 0; i < slashes; i++) kk_os_win_addc(b, '\\'); kk_os_win_addc(b, *p); }
  }
  kk_os_win_addc(b, '"');
}

typedef struct kk_os_win_io_s { HANDLE h; const uint8_t* data; size_t len; kk_os_win_buf_t out; } kk_os_win_io_t;

static DWORD WINAPI kk_os_win_read_all( LPVOID arg ) {
  kk_os_win_io_t* io = (kk_os_win_io_t*)arg;
  char chunk[16*1024];
  DWORD n;
  while (ReadFile(io->h, chunk, sizeof(chunk), &n, NULL) && n > 0) kk_os_win_add(&io->out, chunk, n);
  return 0;
}

static DWORD WINAPI kk_os_win_write_all( LPVOID arg ) {
  kk_os_win_io_t* io = (kk_os_win_io_t*)arg;
  size_t pos = 0;
  DWORD n;
  while (pos < io->len && WriteFile(io->h, io->data + pos, (DWORD)(io->len - pos > 0x10000000 ? 0x10000000 : io->len - pos), &n, NULL)) pos += n;
  CloseHandle(io->h);
  return 0;
}

static int kk_os_win_errno( DWORD e ) {
  switch (e) {
    case ERROR_FILE_NOT_FOUND:
    case ERROR_PATH_NOT_FOUND:
    case ERROR_BAD_PATHNAME:
    case ERROR_DIRECTORY: return ENOENT;
    case ERROR_ACCESS_DENIED: return EACCES;
    case ERROR_NOT_ENOUGH_MEMORY:
    case ERROR_OUTOFMEMORY: return ENOMEM;
    case ERROR_BAD_EXE_FORMAT: return ENOEXEC;
    default: return EIO;
  }
}

static kk_std_core_exn__error kk_os_spawn_win( kk_string_t cmd, kk_vector_t args, kk_bytes_t input, kk_string_t cwd, kk_vector_t env, kk_context_t* ctx ) {
  int err = 0;
  DWORD code = (DWORD)-1;
  kk_os_win_buf_t cl = { NULL, 0, 0 };
  kk_os_win_buf_t envb = { NULL, 0, 0 };
  kk_os_win_io_t in = { NULL, NULL, 0, { NULL, 0, 0 } };
  kk_os_win_io_t out = { NULL, NULL, 0, { NULL, 0, 0 } };
  kk_os_win_io_t errio = { NULL, NULL, 0, { NULL, 0, 0 } };
  HANDLE in_r = NULL, out_w = NULL, err_w = NULL;
  bool done = false;
  // the command line
  kk_os_win_quote(&cl, kk_string_cbuf_borrow(cmd, NULL, ctx));
  kk_ssize_t nargs;
  kk_box_t* xargs = kk_vector_buf_borrow(args, &nargs, ctx);
  for (kk_ssize_t i = 0; i < nargs; i++) {
    kk_os_win_addc(&cl, ' ');
    kk_os_win_quote(&cl, kk_string_cbuf_borrow(kk_string_unbox(xargs[i]), NULL, ctx));
  }
  // the environment block: `name=value` strings, each ended by a NUL, and a final NUL
  kk_ssize_t nenv;
  kk_box_t* xenv = kk_vector_buf_borrow(env, &nenv, ctx);
  for (kk_ssize_t i = 0; i < nenv; i++) {
    kk_ssize_t len;
    const char* e = kk_string_cbuf_borrow(kk_string_unbox(xenv[i]), &len, ctx);
    kk_os_win_add(&envb, e, (size_t)len + 1);
  }
  if (nenv > 0) kk_os_win_addc(&envb, 0);
  // pipes: only the child's ends are inherited
  SECURITY_ATTRIBUTES sa;
  sa.nLength = sizeof(sa); sa.lpSecurityDescriptor = NULL; sa.bInheritHandle = TRUE;
  if (!CreatePipe(&in_r, &in.h, &sa, 0) || !CreatePipe(&out.h, &out_w, &sa, 0) || !CreatePipe(&errio.h, &err_w, &sa, 0)) {
    err = kk_os_win_errno(GetLastError());
    goto cleanup;
  }
  SetHandleInformation(in.h, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(out.h, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(errio.h, HANDLE_FLAG_INHERIT, 0);
  STARTUPINFOA si;
  ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = in_r; si.hStdOutput = out_w; si.hStdError = err_w;
  PROCESS_INFORMATION pi;
  ZeroMemory(&pi, sizeof(pi));
  kk_ssize_t cwdlen;
  const char* ccwd = kk_string_cbuf_borrow(cwd, &cwdlen, ctx);
  if (!CreateProcessA(NULL, cl.buf, NULL, NULL, TRUE, CREATE_NO_WINDOW, (nenv > 0 ? envb.buf : NULL),
                      (cwdlen > 0 ? ccwd : NULL), &si, &pi)) {
    err = kk_os_win_errno(GetLastError());
    goto cleanup;
  }
  CloseHandle(in_r); in_r = NULL;
  CloseHandle(out_w); out_w = NULL;
  CloseHandle(err_w); err_w = NULL;
  kk_ssize_t inlen;
  in.data = kk_bytes_buf_borrow(input, &inlen, ctx);
  in.len = (size_t)inlen;
  HANDLE tw = CreateThread(NULL, 0, &kk_os_win_write_all, &in, 0, NULL);
  if (tw == NULL) kk_os_win_write_all(&in);
  in.h = NULL;   // closed by the writer
  HANDLE tr = CreateThread(NULL, 0, &kk_os_win_read_all, &errio, 0, NULL);
  kk_os_win_read_all(&out);
  if (tr == NULL) kk_os_win_read_all(&errio);
  if (tr != NULL) { WaitForSingleObject(tr, INFINITE); CloseHandle(tr); }
  if (tw != NULL) { WaitForSingleObject(tw, INFINITE); CloseHandle(tw); }
  WaitForSingleObject(pi.hProcess, INFINITE);
  GetExitCodeProcess(pi.hProcess, &code);
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  done = true;
cleanup:
  if (in_r != NULL) CloseHandle(in_r);
  if (out_w != NULL) CloseHandle(out_w);
  if (err_w != NULL) CloseHandle(err_w);
  if (in.h != NULL) CloseHandle(in.h);
  if (out.h != NULL) CloseHandle(out.h);
  if (errio.h != NULL) CloseHandle(errio.h);
  kk_bytes_t bout = kk_bytes_alloc_dupn((kk_ssize_t)out.out.len, (const uint8_t*)out.out.buf, ctx);
  kk_bytes_t berr = kk_bytes_alloc_dupn((kk_ssize_t)errio.out.len, (const uint8_t*)errio.out.buf, ctx);
  free(cl.buf); free(envb.buf); free(out.out.buf); free(errio.out.buf);
  kk_string_drop(cmd,ctx);
  kk_vector_drop(args,ctx);
  kk_bytes_drop(input,ctx);
  kk_string_drop(cwd,ctx);
  kk_vector_drop(env,ctx);
  if (!done) {
    kk_bytes_drop(bout,ctx);
    kk_bytes_drop(berr,ctx);
    return kk_error_from_errno(err != 0 ? err : EIO,ctx);
  }
  kk_std_core_types__tuple3 res = kk_std_core_types__new_Tuple3(
    kk_integer_box(kk_integer_from_int((int)code,ctx),ctx), kk_bytes_box(bout), kk_bytes_box(berr), ctx);
  return kk_error_ok(kk_std_core_types__tuple3_box(res,ctx),ctx);
}
#endif

// Run `cmd` with arguments `args` (the vector does not include the program name),
// feeding `input` on stdin, in directory `cwd` (if not empty), with environment
// `env` (as `name=value` strings; inherit the current environment if empty).
// Returns `(exit-code, stdout, stderr)`.
static kk_std_core_exn__error kk_os_spawn_prim( kk_string_t cmd, kk_vector_t args, kk_bytes_t input, kk_string_t cwd, kk_vector_t env, kk_context_t* ctx ) {
  #if defined(_WIN32)
  return kk_os_spawn_win(cmd, args, input, cwd, env, ctx);
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
