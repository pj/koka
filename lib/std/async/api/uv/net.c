/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

// TCP and UDP networking and child processes on libuv.
//
// A socket (or server, or a pipe to a child process) is a `kk_net_sock_t` boxed as an opaque C pointer; it
// must be closed explicitly with `kk_net_close`. Pending asynchronous
// operations store their Koka callback in the socket itself (not in the uv
// handle `data` field) so a socket can have a pending read and a pending
// write at the same time.

#include <uv.h>
#include <string.h>
#if !defined(_WIN32)
#include <signal.h>
#endif

typedef struct kk_net_sock_s {
  union {
    uv_tcp_t  tcp;                 // must be first: we cast between `uv_tcp_t*`, `uv_stream_t*`, and `kk_net_sock_t*`
    uv_pipe_t pipe;                // a pipe to a child process (see "Child processes")
  };
  bool     has_read_cb;
  kk_function_t read_cb;           // pending read: `error<bytes> -> ioc ()`
  bool     has_conn_cb;
  kk_function_t conn_cb;           // pending wait-for-connection (servers): `error<()> -> ioc ()`
  struct kk_net_sock_s* queue;     // accepted connections that were not yet taken (servers)
  struct kk_net_sock_s* next;      // link in the accept queue
  int      listen_err;             // last error reported to the connection callback (servers)
  bool     closing;
} kk_net_sock_t;

// Writing to a closed socket or pipe must be reported as an `EPIPE` error
// rather than terminating the program with `SIGPIPE` (as Node.js does too).
static void kk_net_ignore_sigpipe(void) {
  #if !defined(_WIN32)
  static bool ignored = false;
  if (!ignored) { ignored = true; signal(SIGPIPE, SIG_IGN); }
  #endif
}

static kk_net_sock_t* kk_net_sock_alloc( uv_loop_t* loop, int* err, kk_context_t* ctx ) {
  kk_net_ignore_sigpipe();
  kk_net_sock_t* sock = (kk_net_sock_t*)kk_zalloc(sizeof(kk_net_sock_t), ctx);
  if (sock == NULL) { *err = UV_ENOMEM; return NULL; }
  *err = uv_tcp_init(loop, &sock->tcp);
  if (*err != 0) { kk_free(sock, ctx); return NULL; }
  return sock;
}

static kk_net_sock_t* kk_net_pipe_alloc( uv_loop_t* loop, int* err, kk_context_t* ctx ) {
  kk_net_ignore_sigpipe();
  kk_net_sock_t* sock = (kk_net_sock_t*)kk_zalloc(sizeof(kk_net_sock_t), ctx);
  if (sock == NULL) { *err = UV_ENOMEM; return NULL; }
  *err = uv_pipe_init(loop, &sock->pipe, 0);
  if (*err != 0) { kk_free(sock, ctx); return NULL; }
  return sock;
}

static kk_net_sock_t* kk_net_sock_unbox( kk_box_t b, kk_context_t* ctx ) {
  return (kk_net_sock_t*)kk_cptr_unbox_borrowed(b, ctx);
}

static kk_std_core_exn__error kk_net_closed_error( kk_context_t* ctx ) {
  return kk_error_from_uv_errno(UV_ECANCELED, ctx);
}

// deliver a result to a pending read
static void kk_net_deliver_read( kk_net_sock_t* sock, kk_std_core_exn__error res, kk_context_t* ctx ) {
  if (!sock->has_read_cb) { kk_std_core_types__result_drop(res, ctx); return; }
  kk_function_t cb = sock->read_cb;
  sock->has_read_cb = false;
  kk_function_call_error(cb, res, ctx);   // drops cb
}

// deliver a result to a pending wait-for-connection
static void kk_net_deliver_conn( kk_net_sock_t* sock, kk_std_core_exn__error res, kk_context_t* ctx ) {
  if (!sock->has_conn_cb) { kk_std_core_types__result_drop(res, ctx); return; }
  kk_function_t cb = sock->conn_cb;
  sock->has_conn_cb = false;
  kk_function_call_error(cb, res, ctx);   // drops cb
}

static void kk_net_free_cb( uv_handle_t* h ) {
  kk_free(h, kk_get_context());
}

static void kk_net_close_sock( kk_net_sock_t* sock, kk_context_t* ctx ) {
  if (sock == NULL || sock->closing) return;
  sock->closing = true;
  uv_read_stop((uv_stream_t*)&sock->tcp);
  kk_net_deliver_read(sock, kk_net_closed_error(ctx), ctx);
  kk_net_deliver_conn(sock, kk_net_closed_error(ctx), ctx);
  // close connections that were accepted but never taken
  kk_net_sock_t* q = sock->queue;
  sock->queue = NULL;
  while (q != NULL) {
    kk_net_sock_t* next = q->next;
    kk_net_close_sock(q, ctx);
    q = next;
  }
  uv_close((uv_handle_t*)&sock->tcp, &kk_net_free_cb);
}

kk_unit_t kk_net_close( kk_box_t sock, kk_context_t* ctx ) {
  kk_net_close_sock(kk_net_sock_unbox(sock, ctx), ctx);
  kk_box_drop(sock, ctx);
  return kk_Unit;
}

// ---------------------------------------------------------------------------
// Name resolution
// ---------------------------------------------------------------------------

typedef struct kk_net_getaddrinfo_s {
  uv_getaddrinfo_t req;   // must be first
  int status;
} kk_net_getaddrinfo_t;

static void kk_net_resolve_call( kk_function_t cb, uv_req_t* _req, kk_context_t* ctx ) {
  kk_net_getaddrinfo_t* req = (kk_net_getaddrinfo_t*)_req;
  kk_std_core_exn__error res;
  if (req->status < 0) {
    res = kk_error_from_uv_errno(req->status, ctx);
  }
  else {
    // count, then collect the addresses as strings
    kk_ssize_t n = 0;
    for (struct addrinfo* ai = req->req.addrinfo; ai != NULL; ai = ai->ai_next) {
      if (ai->ai_family == AF_INET || ai->ai_family == AF_INET6) n++;
    }
    kk_box_t* buf;
    kk_vector_t v = kk_vector_alloc_uninit(n, &buf, ctx);
    kk_ssize_t i = 0;
    for (struct addrinfo* ai = req->req.addrinfo; ai != NULL && i < n; ai = ai->ai_next) {
      char name[64];
      name[0] = 0;
      if (ai->ai_family == AF_INET)       uv_ip4_name((struct sockaddr_in*)ai->ai_addr, name, sizeof(name));
      else if (ai->ai_family == AF_INET6) uv_ip6_name((struct sockaddr_in6*)ai->ai_addr, name, sizeof(name));
      else continue;
      buf[i++] = kk_string_box(kk_string_alloc_from_utf8(name, ctx));
    }
    res = kk_result_ok(kk_vector_box(v, ctx), ctx);
  }
  kk_function_call_error(cb, res, ctx);
}

static void kk_net_resolve_cb( uv_getaddrinfo_t* _req, int status, struct addrinfo* res ) {
  kk_net_getaddrinfo_t* req = (kk_net_getaddrinfo_t*)_req;
  req->status = status;
  kk_uv_req_callback((uv_req_t*)req, &kk_net_resolve_call);   // frees the request (not the addrinfo)
  if (res != NULL) uv_freeaddrinfo(res);
}

kk_std_core_exn__error kk_net_resolve_setup( kk_uv_loop_t loop, kk_string_t host, kk_function_t cb, kk_context_t* ctx ) {
  kk_net_getaddrinfo_t* req;
  int err = kk_uv_req_create(sizeof(kk_net_getaddrinfo_t), cb, (uv_req_t**)&req, ctx);
  if (err != 0) { kk_string_drop(host, ctx); return kk_error_from_uv_errno(err, ctx); }
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  kk_with_string_as_qutf8_borrow(host, chost, ctx) {
    err = uv_getaddrinfo(kk_uv_loop(loop, ctx), &req->req, &kk_net_resolve_cb, chost, NULL, &hints);
  }
  kk_string_drop(host, ctx);
  if (err != 0) { kk_uv_req_free((uv_req_t*)req, ctx); return kk_error_from_uv_errno(err, ctx); }
  return kk_result_uv_req_dispose0((uv_req_t*)req, ctx);
}

// ---------------------------------------------------------------------------
// Connecting
// ---------------------------------------------------------------------------

static int kk_net_sockaddr( kk_string_t ip, int32_t port, struct sockaddr_storage* addr, kk_context_t* ctx ) {
  int err = 0;
  kk_with_string_as_qutf8_borrow(ip, cip, ctx) {
    if (strchr(cip, ':') != NULL) err = uv_ip6_addr(cip, port, (struct sockaddr_in6*)addr);
                             else err = uv_ip4_addr(cip, port, (struct sockaddr_in*)addr);
  }
  return err;
}

typedef struct kk_net_connect_s {
  uv_connect_t req;          // must be first
  kk_net_sock_t* sock;
  int status;
} kk_net_connect_t;

static void kk_net_connect_call( kk_function_t cb, uv_req_t* _req, kk_context_t* ctx ) {
  kk_net_connect_t* req = (kk_net_connect_t*)_req;
  kk_std_core_exn__error res;
  if (req->status < 0) {
    kk_net_close_sock(req->sock, ctx);
    res = kk_error_from_uv_errno(req->status, ctx);
  }
  else {
    res = kk_result_ok(kk_cptr_box(req->sock, ctx), ctx);
  }
  req->sock = NULL;
  kk_function_call_error(cb, res, ctx);
}

static void kk_net_connect_cb( uv_connect_t* _req, int status ) {
  kk_net_connect_t* req = (kk_net_connect_t*)_req;
  req->status = status;
  if (req->req.data == NULL && req->sock != NULL) {
    // the connect was canceled: nobody will take ownership of the socket
    kk_net_close_sock(req->sock, kk_get_context());
    req->sock = NULL;
  }
  kk_uv_req_callback((uv_req_t*)req, &kk_net_connect_call);
}

kk_std_core_exn__error kk_net_connect_setup( kk_uv_loop_t loop, kk_string_t ip, int32_t port, kk_function_t cb, kk_context_t* ctx ) {
  struct sockaddr_storage addr;
  int err = kk_net_sockaddr(ip, port, &addr, ctx);
  kk_string_drop(ip, ctx);
  if (err != 0) { kk_function_drop(cb, ctx); return kk_error_from_uv_errno(err, ctx); }
  kk_net_sock_t* sock = kk_net_sock_alloc(kk_uv_loop(loop, ctx), &err, ctx);
  if (sock == NULL) { kk_function_drop(cb, ctx); return kk_error_from_uv_errno(err, ctx); }
  kk_net_connect_t* req;
  err = kk_uv_req_create(sizeof(kk_net_connect_t), cb, (uv_req_t**)&req, ctx);
  if (err != 0) { kk_net_close_sock(sock, ctx); return kk_error_from_uv_errno(err, ctx); }
  req->sock = sock;
  err = uv_tcp_connect(&req->req, &sock->tcp, (const struct sockaddr*)&addr, &kk_net_connect_cb);
  if (err != 0) {
    kk_net_close_sock(sock, ctx);
    kk_uv_req_free((uv_req_t*)req, ctx);
    return kk_error_from_uv_errno(err, ctx);
  }
  return kk_result_uv_req_dispose0((uv_req_t*)req, ctx);
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

static void kk_net_alloc_cb( uv_handle_t* h, size_t suggested, uv_buf_t* buf ) {
  kk_unused(h);
  buf->base = (char*)kk_malloc((kk_ssize_t)suggested, kk_get_context());
  buf->len  = (buf->base == NULL ? 0 : suggested);
}

static void kk_net_read_cb( uv_stream_t* stream, ssize_t nread, const uv_buf_t* buf ) {
  kk_context_t* ctx = kk_get_context();
  kk_net_sock_t* sock = (kk_net_sock_t*)stream;
  if (nread == 0) {  // EAGAIN; nothing read
    if (buf->base != NULL) kk_free(buf->base, ctx);
    return;
  }
  uv_read_stop(stream);   // we read one chunk per request
  kk_std_core_exn__error res;
  if (nread == UV_EOF) {
    res = kk_result_ok(kk_bytes_box(kk_bytes_empty()), ctx);
  }
  else if (nread < 0) {
    res = kk_error_from_uv_errno((int)nread, ctx);
  }
  else {
    res = kk_result_ok(kk_bytes_box(kk_bytes_alloc_dupn((kk_ssize_t)nread, (const uint8_t*)buf->base, ctx)), ctx);
  }
  if (buf->base != NULL) kk_free(buf->base, ctx);
  kk_net_deliver_read(sock, res, ctx);
}

static void kk_net_read_dispose( uv_handle_t* h, void* arg, kk_context_t* ctx ) {
  kk_unused(arg);
  kk_net_sock_t* sock = (kk_net_sock_t*)h;
  if (sock->closing) return;
  uv_read_stop((uv_stream_t*)&sock->tcp);
  if (sock->has_read_cb) {
    sock->has_read_cb = false;
    kk_function_drop(sock->read_cb, ctx);
  }
}

// Read the next chunk of data; an empty chunk signifies end-of-stream.
kk_std_core_exn__error kk_net_read_setup( kk_uv_loop_t loop, kk_box_t bsock, kk_function_t cb, kk_context_t* ctx ) {
  kk_unused(loop);
  kk_net_sock_t* sock = kk_net_sock_unbox(bsock, ctx);
  kk_box_drop(bsock, ctx);
  if (sock->closing) { kk_function_drop(cb, ctx); return kk_net_closed_error(ctx); }
  if (sock->has_read_cb) { kk_function_drop(cb, ctx); return kk_error_from_uv_errno(UV_EALREADY, ctx); }
  sock->read_cb = cb;
  sock->has_read_cb = true;
  int err = uv_read_start((uv_stream_t*)&sock->tcp, &kk_net_alloc_cb, &kk_net_read_cb);
  if (err != 0) {
    sock->has_read_cb = false;
    kk_function_drop(sock->read_cb, ctx);
    return kk_error_from_uv_errno(err, ctx);
  }
  return kk_result_uv_handle_dispose((uv_handle_t*)sock, NULL, &kk_net_read_dispose, ctx);
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

typedef struct kk_net_write_s {
  uv_write_t req;           // must be first
  kk_bytes_t data;          // keep the data alive during the write
  int status;
} kk_net_write_t;

static void kk_net_write_call( kk_function_t cb, uv_req_t* _req, kk_context_t* ctx ) {
  kk_net_write_t* req = (kk_net_write_t*)_req;
  kk_std_core_exn__error res = (req->status < 0 ? kk_error_from_uv_errno(req->status, ctx)
                                                : kk_result_ok(kk_unit_box(kk_Unit), ctx));
  kk_function_call_error(cb, res, ctx);
}

static void kk_net_write_cb( uv_write_t* _req, int status ) {
  kk_net_write_t* req = (kk_net_write_t*)_req;
  req->status = status;
  kk_bytes_drop(req->data, kk_get_context());
  req->data = kk_bytes_empty();
  kk_uv_req_callback((uv_req_t*)req, &kk_net_write_call);
}

kk_std_core_exn__error kk_net_write_setup( kk_uv_loop_t loop, kk_box_t bsock, kk_bytes_t data, kk_function_t cb, kk_context_t* ctx ) {
  kk_unused(loop);
  kk_net_sock_t* sock = kk_net_sock_unbox(bsock, ctx);
  kk_box_drop(bsock, ctx);
  if (sock->closing) { kk_bytes_drop(data, ctx); kk_function_drop(cb, ctx); return kk_net_closed_error(ctx); }
  kk_net_write_t* req;
  int err = kk_uv_req_create(sizeof(kk_net_write_t), cb, (uv_req_t**)&req, ctx);
  if (err != 0) { kk_bytes_drop(data, ctx); return kk_error_from_uv_errno(err, ctx); }
  req->data = data;
  kk_ssize_t len = 0;
  const uint8_t* base = kk_bytes_buf_borrow(data, &len, ctx);
  uv_buf_t bufs[1];
  bufs[0] = uv_buf_init((char*)base, (unsigned int)len);
  err = uv_write(&req->req, (uv_stream_t*)&sock->tcp, bufs, 1, &kk_net_write_cb);
  if (err != 0) {
    kk_bytes_drop(req->data, ctx);
    req->data = kk_bytes_empty();
    kk_uv_req_free((uv_req_t*)req, ctx);
    return kk_error_from_uv_errno(err, ctx);
  }
  return kk_result_uv_req_dispose0((uv_req_t*)req, ctx);
}

// ---------------------------------------------------------------------------
// Shutdown (half close: no more writes)
// ---------------------------------------------------------------------------

typedef struct kk_net_shutdown_s {
  uv_shutdown_t req;        // must be first
  int status;
} kk_net_shutdown_t;

static void kk_net_shutdown_call( kk_function_t cb, uv_req_t* _req, kk_context_t* ctx ) {
  kk_net_shutdown_t* req = (kk_net_shutdown_t*)_req;
  kk_std_core_exn__error res = (req->status < 0 && req->status != UV_ENOTCONN ? kk_error_from_uv_errno(req->status, ctx)
                                                                             : kk_result_ok(kk_unit_box(kk_Unit), ctx));
  kk_function_call_error(cb, res, ctx);
}

static void kk_net_shutdown_cb( uv_shutdown_t* _req, int status ) {
  ((kk_net_shutdown_t*)_req)->status = status;
  kk_uv_req_callback((uv_req_t*)_req, &kk_net_shutdown_call);
}

kk_std_core_exn__error kk_net_shutdown_setup( kk_uv_loop_t loop, kk_box_t bsock, kk_function_t cb, kk_context_t* ctx ) {
  kk_unused(loop);
  kk_net_sock_t* sock = kk_net_sock_unbox(bsock, ctx);
  kk_box_drop(bsock, ctx);
  if (sock->closing) { kk_function_drop(cb, ctx); return kk_net_closed_error(ctx); }
  kk_net_shutdown_t* req;
  int err = kk_uv_req_create(sizeof(kk_net_shutdown_t), cb, (uv_req_t**)&req, ctx);
  if (err != 0) return kk_error_from_uv_errno(err, ctx);
  err = uv_shutdown(&req->req, (uv_stream_t*)&sock->tcp, &kk_net_shutdown_cb);
  if (err != 0) { kk_uv_req_free((uv_req_t*)req, ctx); return kk_error_from_uv_errno(err, ctx); }
  return kk_result_uv_req_dispose0((uv_req_t*)req, ctx);
}

// ---------------------------------------------------------------------------
// Servers
// ---------------------------------------------------------------------------

static void kk_net_connection_cb( uv_stream_t* server_stream, int status ) {
  kk_context_t* ctx = kk_get_context();
  kk_net_sock_t* server = (kk_net_sock_t*)server_stream;
  if (server->closing) return;
  if (status < 0) {
    server->listen_err = status;
    kk_net_deliver_conn(server, kk_error_from_uv_errno(status, ctx), ctx);
    return;
  }
  int err;
  kk_net_sock_t* client = kk_net_sock_alloc(server->tcp.loop, &err, ctx);
  if (client == NULL) {
    kk_net_deliver_conn(server, kk_error_from_uv_errno(err, ctx), ctx);
    return;
  }
  err = uv_accept(server_stream, (uv_stream_t*)&client->tcp);
  if (err != 0) {
    kk_net_close_sock(client, ctx);
    kk_net_deliver_conn(server, kk_error_from_uv_errno(err, ctx), ctx);
    return;
  }
  // append to the accept queue
  client->next = NULL;
  if (server->queue == NULL) {
    server->queue = client;
  }
  else {
    kk_net_sock_t* q = server->queue;
    while (q->next != NULL) q = q->next;
    q->next = client;
  }
  kk_net_deliver_conn(server, kk_result_ok(kk_unit_box(kk_Unit), ctx), ctx);
}

// Bind and listen; the result is delivered right away.
kk_std_core_exn__error kk_net_listen_setup( kk_uv_loop_t loop, kk_string_t ip, int32_t port, int32_t backlog, kk_function_t cb, kk_context_t* ctx ) {
  struct sockaddr_storage addr;
  int err = kk_net_sockaddr(ip, port, &addr, ctx);
  kk_string_drop(ip, ctx);
  if (err != 0) { kk_function_drop(cb, ctx); return kk_error_from_uv_errno(err, ctx); }
  kk_net_sock_t* server = kk_net_sock_alloc(kk_uv_loop(loop, ctx), &err, ctx);
  if (server == NULL) { kk_function_drop(cb, ctx); return kk_error_from_uv_errno(err, ctx); }
  err = uv_tcp_bind(&server->tcp, (const struct sockaddr*)&addr, 0);
  if (err == 0) err = uv_listen((uv_stream_t*)&server->tcp, (backlog <= 0 ? 128 : backlog), &kk_net_connection_cb);
  if (err != 0) {
    kk_net_close_sock(server, ctx);
    kk_function_drop(cb, ctx);
    return kk_error_from_uv_errno(err, ctx);
  }
  kk_function_call_error(cb, kk_result_ok(kk_cptr_box(server, ctx), ctx), ctx);
  return kk_result_uv_handle_dispose((uv_handle_t*)NULL, NULL, &kk_uv_handle_dispose, ctx);
}

// Take an accepted connection from the queue (if any).
kk_std_core_types__maybe kk_net_try_accept( kk_box_t bserver, kk_context_t* ctx ) {
  kk_net_sock_t* server = kk_net_sock_unbox(bserver, ctx);
  kk_box_drop(bserver, ctx);
  kk_net_sock_t* client = server->queue;
  if (client == NULL) return kk_std_core_types__new_Nothing(ctx);
  server->queue = client->next;
  client->next = NULL;
  return kk_std_core_types__new_Just(kk_cptr_box(client, ctx), ctx);
}

static void kk_net_conn_dispose( uv_handle_t* h, void* arg, kk_context_t* ctx ) {
  kk_unused(arg);
  kk_net_sock_t* server = (kk_net_sock_t*)h;
  if (server->has_conn_cb) {
    server->has_conn_cb = false;
    kk_function_drop(server->conn_cb, ctx);
  }
}

// Wait until a connection is queued (or the server fails).
kk_std_core_exn__error kk_net_wait_connection_setup( kk_uv_loop_t loop, kk_box_t bserver, kk_function_t cb, kk_context_t* ctx ) {
  kk_unused(loop);
  kk_net_sock_t* server = kk_net_sock_unbox(bserver, ctx);
  kk_box_drop(bserver, ctx);
  if (server->closing) { kk_function_drop(cb, ctx); return kk_net_closed_error(ctx); }
  if (server->has_conn_cb) { kk_function_drop(cb, ctx); return kk_error_from_uv_errno(UV_EALREADY, ctx); }
  server->conn_cb = cb;
  server->has_conn_cb = true;
  return kk_result_uv_handle_dispose((uv_handle_t*)server, NULL, &kk_net_conn_dispose, ctx);
}

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

static kk_string_t kk_net_addr_string( struct sockaddr_storage* addr, int32_t* port, kk_context_t* ctx ) {
  char name[64];
  name[0] = 0;
  *port = 0;
  if (addr->ss_family == AF_INET) {
    uv_ip4_name((struct sockaddr_in*)addr, name, sizeof(name));
    *port = ntohs(((struct sockaddr_in*)addr)->sin_port);
  }
  else if (addr->ss_family == AF_INET6) {
    uv_ip6_name((struct sockaddr_in6*)addr, name, sizeof(name));
    *port = ntohs(((struct sockaddr_in6*)addr)->sin6_port);
  }
  return kk_string_alloc_from_utf8(name, ctx);
}

// Returns `(ip, port)` of the local (`peer == false`) or remote end.
kk_std_core_types__tuple2 kk_net_address( kk_box_t bsock, bool peer, kk_context_t* ctx ) {
  kk_net_sock_t* sock = kk_net_sock_unbox(bsock, ctx);
  kk_box_drop(bsock, ctx);
  struct sockaddr_storage addr;
  memset(&addr, 0, sizeof(addr));
  int len = sizeof(addr);
  if (peer) uv_tcp_getpeername(&sock->tcp, (struct sockaddr*)&addr, &len);
       else uv_tcp_getsockname(&sock->tcp, (struct sockaddr*)&addr, &len);
  int32_t port;
  kk_string_t ip = kk_net_addr_string(&addr, &port, ctx);
  return kk_std_core_types__new_Tuple2(kk_string_box(ip), kk_integer_box(kk_integer_from_int(port, ctx), ctx), ctx);
}

kk_unit_t kk_net_set_nodelay( kk_box_t bsock, bool enable, kk_context_t* ctx ) {
  kk_net_sock_t* sock = kk_net_sock_unbox(bsock, ctx);
  kk_box_drop(bsock, ctx);
  uv_tcp_nodelay(&sock->tcp, enable ? 1 : 0);
  return kk_Unit;
}

kk_string_t kk_net_tls_alpn( kk_box_t sock, kk_context_t* ctx ) {
  kk_box_drop(sock, ctx);
  return kk_string_empty();
}

kk_string_t kk_net_tls_peer_subject( kk_box_t sock, kk_context_t* ctx ) {
  kk_box_drop(sock, ctx);
  return kk_string_empty();
}

// ---------------------------------------------------------------------------
// UDP
// ---------------------------------------------------------------------------

typedef struct kk_udp_s {
  uv_udp_t udp;                    // must be first
  bool     has_recv_cb;
  kk_function_t recv_cb;           // pending receive: `error<(bytes,string,int)> -> ioc ()`
  bool     closing;
} kk_udp_t;

static kk_udp_t* kk_udp_unbox( kk_box_t b, kk_context_t* ctx ) {
  return (kk_udp_t*)kk_cptr_unbox_borrowed(b, ctx);
}

static void kk_udp_deliver_recv( kk_udp_t* u, kk_std_core_exn__error res, kk_context_t* ctx ) {
  if (!u->has_recv_cb) { kk_std_core_types__result_drop(res, ctx); return; }
  kk_function_t cb = u->recv_cb;
  u->has_recv_cb = false;
  kk_function_call_error(cb, res, ctx);   // drops cb
}

// Bind a UDP socket to `ip` and `port` (`0` picks a free port); the result is delivered right away.
kk_std_core_exn__error kk_udp_bind_setup( kk_uv_loop_t loop, kk_string_t ip, int32_t port, kk_function_t cb, kk_context_t* ctx ) {
  struct sockaddr_storage addr;
  int err = kk_net_sockaddr(ip, port, &addr, ctx);
  kk_string_drop(ip, ctx);
  if (err != 0) { kk_function_drop(cb, ctx); return kk_error_from_uv_errno(err, ctx); }
  kk_udp_t* u = (kk_udp_t*)kk_zalloc(sizeof(kk_udp_t), ctx);
  if (u == NULL) { kk_function_drop(cb, ctx); return kk_error_from_uv_errno(UV_ENOMEM, ctx); }
  err = uv_udp_init(kk_uv_loop(loop, ctx), &u->udp);
  if (err != 0) { kk_free(u, ctx); kk_function_drop(cb, ctx); return kk_error_from_uv_errno(err, ctx); }
  err = uv_udp_bind(&u->udp, (const struct sockaddr*)&addr, 0);
  if (err != 0) {
    u->closing = true;
    uv_close((uv_handle_t*)&u->udp, &kk_net_free_cb);
    kk_function_drop(cb, ctx);
    return kk_error_from_uv_errno(err, ctx);
  }
  kk_function_call_error(cb, kk_result_ok(kk_cptr_box(u, ctx), ctx), ctx);
  return kk_result_uv_handle_dispose((uv_handle_t*)NULL, NULL, &kk_uv_handle_dispose, ctx);
}

static void kk_udp_recv_cb( uv_udp_t* handle, ssize_t nread, const uv_buf_t* buf, const struct sockaddr* addr, unsigned flags ) {
  kk_unused(flags);
  kk_context_t* ctx = kk_get_context();
  kk_udp_t* u = (kk_udp_t*)handle;
  if (nread == 0 && addr == NULL) {  // nothing more to read
    if (buf->base != NULL) kk_free(buf->base, ctx);
    return;
  }
  uv_udp_recv_stop(handle);   // we receive one datagram per request
  kk_std_core_exn__error res;
  if (nread < 0) {
    res = kk_error_from_uv_errno((int)nread, ctx);
  }
  else {
    struct sockaddr_storage from;
    memset(&from, 0, sizeof(from));
    if (addr != NULL) memcpy(&from, addr, (addr->sa_family == AF_INET6 ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in)));
    int32_t port;
    kk_string_t ip = kk_net_addr_string(&from, &port, ctx);
    kk_bytes_t data = (nread == 0 ? kk_bytes_empty() : kk_bytes_alloc_dupn((kk_ssize_t)nread, (const uint8_t*)buf->base, ctx));
    res = kk_result_ok(kk_std_core_types__tuple3_box(kk_std_core_types__new_Tuple3(kk_bytes_box(data), kk_string_box(ip),
                         kk_integer_box(kk_integer_from_int(port, ctx), ctx), ctx), ctx), ctx);
  }
  if (buf->base != NULL) kk_free(buf->base, ctx);
  kk_udp_deliver_recv(u, res, ctx);
}

static void kk_udp_recv_dispose( uv_handle_t* h, void* arg, kk_context_t* ctx ) {
  kk_unused(arg);
  kk_udp_t* u = (kk_udp_t*)h;
  if (u->closing) return;
  uv_udp_recv_stop(&u->udp);
  if (u->has_recv_cb) {
    u->has_recv_cb = false;
    kk_function_drop(u->recv_cb, ctx);
  }
}

// Receive the next datagram as `(data, sender-ip, sender-port)`.
kk_std_core_exn__error kk_udp_recv_setup( kk_uv_loop_t loop, kk_box_t bu, kk_function_t cb, kk_context_t* ctx ) {
  kk_unused(loop);
  kk_udp_t* u = kk_udp_unbox(bu, ctx);
  kk_box_drop(bu, ctx);
  if (u->closing) { kk_function_drop(cb, ctx); return kk_net_closed_error(ctx); }
  if (u->has_recv_cb) { kk_function_drop(cb, ctx); return kk_error_from_uv_errno(UV_EALREADY, ctx); }
  u->recv_cb = cb;
  u->has_recv_cb = true;
  int err = uv_udp_recv_start(&u->udp, &kk_net_alloc_cb, &kk_udp_recv_cb);
  if (err != 0) {
    u->has_recv_cb = false;
    kk_function_drop(u->recv_cb, ctx);
    return kk_error_from_uv_errno(err, ctx);
  }
  return kk_result_uv_handle_dispose((uv_handle_t*)u, NULL, &kk_udp_recv_dispose, ctx);
}

typedef struct kk_udp_send_s {
  uv_udp_send_t req;        // must be first
  kk_bytes_t data;          // keep the data alive during the send
  int status;
} kk_udp_send_t;

static void kk_udp_send_call( kk_function_t cb, uv_req_t* _req, kk_context_t* ctx ) {
  kk_udp_send_t* req = (kk_udp_send_t*)_req;
  kk_std_core_exn__error res = (req->status < 0 ? kk_error_from_uv_errno(req->status, ctx)
                                                : kk_result_ok(kk_unit_box(kk_Unit), ctx));
  kk_function_call_error(cb, res, ctx);
}

static void kk_udp_send_cb( uv_udp_send_t* _req, int status ) {
  kk_udp_send_t* req = (kk_udp_send_t*)_req;
  req->status = status;
  kk_bytes_drop(req->data, kk_get_context());
  req->data = kk_bytes_empty();
  kk_uv_req_callback((uv_req_t*)req, &kk_udp_send_call);
}

// Send a datagram to `ip` and `port`.
kk_std_core_exn__error kk_udp_send_setup( kk_uv_loop_t loop, kk_box_t bu, kk_bytes_t data, kk_string_t ip, int32_t port, kk_function_t cb, kk_context_t* ctx ) {
  kk_unused(loop);
  kk_udp_t* u = kk_udp_unbox(bu, ctx);
  kk_box_drop(bu, ctx);
  struct sockaddr_storage addr;
  // an empty `ip` sends to the connected peer
  const bool connected = (kk_string_len_borrow(ip, ctx) == 0);
  int err = (connected ? 0 : kk_net_sockaddr(ip, port, &addr, ctx));
  if (connected) kk_string_drop(ip, ctx);
  if (err == 0 && u->closing) err = UV_ECANCELED;
  if (err != 0) { kk_bytes_drop(data, ctx); kk_function_drop(cb, ctx); return kk_error_from_uv_errno(err, ctx); }
  kk_udp_send_t* req;
  err = kk_uv_req_create(sizeof(kk_udp_send_t), cb, (uv_req_t**)&req, ctx);
  if (err != 0) { kk_bytes_drop(data, ctx); return kk_error_from_uv_errno(err, ctx); }
  req->data = data;
  kk_ssize_t len = 0;
  const uint8_t* base = kk_bytes_buf_borrow(data, &len, ctx);
  uv_buf_t bufs[1];
  bufs[0] = uv_buf_init((char*)base, (unsigned int)len);
  err = uv_udp_send(&req->req, &u->udp, bufs, 1, (connected ? NULL : (const struct sockaddr*)&addr), &kk_udp_send_cb);
  if (err != 0) {
    kk_bytes_drop(req->data, ctx);
    req->data = kk_bytes_empty();
    kk_uv_req_free((uv_req_t*)req, ctx);
    return kk_error_from_uv_errno(err, ctx);
  }
  return kk_result_uv_req_dispose0((uv_req_t*)req, ctx);
}

kk_unit_t kk_udp_close( kk_box_t bu, kk_context_t* ctx ) {
  kk_udp_t* u = kk_udp_unbox(bu, ctx);
  kk_box_drop(bu, ctx);
  if (!u->closing) {
    u->closing = true;
    uv_udp_recv_stop(&u->udp);
    kk_udp_deliver_recv(u, kk_net_closed_error(ctx), ctx);
    uv_close((uv_handle_t*)&u->udp, &kk_net_free_cb);
  }
  return kk_Unit;
}

kk_std_core_types__tuple2 kk_udp_address( kk_box_t bu, kk_context_t* ctx ) {
  kk_udp_t* u = kk_udp_unbox(bu, ctx);
  kk_box_drop(bu, ctx);
  struct sockaddr_storage addr;
  memset(&addr, 0, sizeof(addr));
  int len = sizeof(addr);
  uv_udp_getsockname(&u->udp, (struct sockaddr*)&addr, &len);
  int32_t port;
  kk_string_t ip = kk_net_addr_string(&addr, &port, ctx);
  return kk_std_core_types__new_Tuple2(kk_string_box(ip), kk_integer_box(kk_integer_from_int(port, ctx), ctx), ctx);
}

kk_std_core_exn__error kk_udp_set_broadcast( kk_box_t bu, bool enable, kk_context_t* ctx ) {
  kk_udp_t* u = kk_udp_unbox(bu, ctx);
  kk_box_drop(bu, ctx);
  int err = uv_udp_set_broadcast(&u->udp, enable ? 1 : 0);
  if (err != 0) return kk_error_from_uv_errno(err, ctx);
  return kk_result_ok(kk_unit_box(kk_Unit), ctx);
}

// Connect to a peer (or disconnect with an empty `ip`): datagrams are then sent
// to it without an address, and only datagrams from it are received.
kk_std_core_exn__error kk_udp_connect( kk_box_t bu, kk_string_t ip, int32_t port, kk_context_t* ctx ) {
  kk_udp_t* u = kk_udp_unbox(bu, ctx);
  kk_box_drop(bu, ctx);
  int err;
  if (kk_string_len_borrow(ip, ctx) == 0) {
    kk_string_drop(ip, ctx);
    err = uv_udp_connect(&u->udp, NULL);
    if (err == UV_ENOTCONN) err = 0;
  }
  else {
    struct sockaddr_storage addr;
    err = kk_net_sockaddr(ip, port, &addr, ctx);
    if (err == 0) err = uv_udp_connect(&u->udp, (const struct sockaddr*)&addr);
  }
  if (err != 0) return kk_error_from_uv_errno(err, ctx);
  return kk_result_ok(kk_unit_box(kk_Unit), ctx);
}

kk_std_core_exn__error kk_udp_connect_setup( kk_uv_loop_t loop, kk_box_t bu, kk_string_t ip, int32_t port, kk_function_t cb, kk_context_t* ctx ) {
  kk_unused(loop); kk_box_drop(bu, ctx); kk_string_drop(ip, ctx); kk_function_drop(cb, ctx);
  return kk_error_from_uv_errno(UV_ENOTSUP, ctx);   // only used on Node.js
}

// The address of the connected peer, or `("", 0)`.
kk_std_core_types__tuple2 kk_udp_peer_address( kk_box_t bu, kk_context_t* ctx ) {
  kk_udp_t* u = kk_udp_unbox(bu, ctx);
  kk_box_drop(bu, ctx);
  struct sockaddr_storage addr;
  int len = sizeof(addr);
  char ipbuf[64] = "";
  int port = 0;
  if (uv_udp_getpeername(&u->udp, (struct sockaddr*)&addr, &len) == 0) {
    if (addr.ss_family == AF_INET6) {
      uv_ip6_name((const struct sockaddr_in6*)&addr, ipbuf, sizeof(ipbuf));
      port = ntohs(((const struct sockaddr_in6*)&addr)->sin6_port);
    }
    else {
      uv_ip4_name((const struct sockaddr_in*)&addr, ipbuf, sizeof(ipbuf));
      port = ntohs(((const struct sockaddr_in*)&addr)->sin_port);
    }
  }
  return kk_std_core_types__new_Tuple2(kk_string_box(kk_string_alloc_from_utf8(ipbuf, ctx)), kk_integer_box(kk_integer_from_int(port, ctx), ctx), ctx);
}

// Join (or leave) the multicast `group`, on the interface with address `iface` ("" for the default).
kk_std_core_exn__error kk_udp_set_membership( kk_box_t bu, kk_string_t group, kk_string_t iface, bool join, kk_context_t* ctx ) {
  kk_udp_t* u = kk_udp_unbox(bu, ctx);
  kk_box_drop(bu, ctx);
  kk_ssize_t ilen;
  const char* ip = kk_string_cbuf_borrow(iface, &ilen, ctx);
  int err = uv_udp_set_membership(&u->udp, kk_string_cbuf_borrow(group, NULL, ctx), (ilen == 0 ? NULL : ip), join ? UV_JOIN_GROUP : UV_LEAVE_GROUP);
  kk_string_drop(group, ctx);
  kk_string_drop(iface, ctx);
  if (err != 0) return kk_error_from_uv_errno(err, ctx);
  return kk_result_ok(kk_unit_box(kk_Unit), ctx);
}

kk_std_core_exn__error kk_udp_set_multicast_ttl( kk_box_t bu, int32_t ttl, kk_context_t* ctx ) {
  kk_udp_t* u = kk_udp_unbox(bu, ctx);
  kk_box_drop(bu, ctx);
  int err = uv_udp_set_multicast_ttl(&u->udp, ttl);
  if (err != 0) return kk_error_from_uv_errno(err, ctx);
  return kk_result_ok(kk_unit_box(kk_Unit), ctx);
}

kk_std_core_exn__error kk_udp_set_multicast_loop( kk_box_t bu, bool enable, kk_context_t* ctx ) {
  kk_udp_t* u = kk_udp_unbox(bu, ctx);
  kk_box_drop(bu, ctx);
  int err = uv_udp_set_multicast_loop(&u->udp, enable ? 1 : 0);
  if (err != 0) return kk_error_from_uv_errno(err, ctx);
  return kk_result_ok(kk_unit_box(kk_Unit), ctx);
}

kk_std_core_exn__error kk_udp_set_multicast_interface( kk_box_t bu, kk_string_t iface, kk_context_t* ctx ) {
  kk_udp_t* u = kk_udp_unbox(bu, ctx);
  kk_box_drop(bu, ctx);
  int err = uv_udp_set_multicast_interface(&u->udp, kk_string_cbuf_borrow(iface, NULL, ctx));
  kk_string_drop(iface, ctx);
  if (err != 0) return kk_error_from_uv_errno(err, ctx);
  return kk_result_ok(kk_unit_box(kk_Unit), ctx);
}

// TLS is implemented in Koka on top of the mbedtls engine for the C backend (see `tls.c`)
kk_std_core_exn__error kk_net_tls_connect_setup( kk_uv_loop_t loop, kk_string_t host, int32_t port, kk_string_t servername, bool verify, kk_string_t ca, kk_string_t crl,
                                                 kk_string_t cert, kk_string_t key, kk_string_t alpn, kk_function_t cb, kk_context_t* ctx ) {
  kk_unused(loop); kk_unused(port); kk_unused(verify);
  kk_string_drop(host, ctx);
  kk_string_drop(servername, ctx);
  kk_string_drop(crl, ctx);
  kk_string_drop(ca, ctx);
  kk_string_drop(cert, ctx);
  kk_string_drop(key, ctx);
  kk_string_drop(alpn, ctx);
  kk_function_drop(cb, ctx);
  return kk_error_from_uv_errno(UV_ENOTSUP, ctx);
}

kk_std_core_exn__error kk_net_tls_accept_setup( kk_uv_loop_t loop, kk_box_t sock, kk_box_t conf, kk_function_t cb, kk_context_t* ctx ) {
  kk_unused(loop);
  kk_box_drop(sock, ctx);
  kk_box_drop(conf, ctx);
  kk_function_drop(cb, ctx);
  return kk_error_from_uv_errno(UV_ENOTSUP, ctx);
}

// ---------------------------------------------------------------------------
// Child processes
//
// The standard input, output and error pipes of a child process are sockets
// (`kk_net_sock_t` over a `uv_pipe_t`), so the reading and writing
// primitives above work on them unchanged.
// ---------------------------------------------------------------------------

typedef struct kk_proc_s {
  uv_process_t process;            // must be first
  bool     exited;
  int32_t  exit_code;              // 128+N if killed by signal N
  bool     has_wait_cb;
  kk_function_t wait_cb;           // pending wait: `error<int32> -> ioc ()`  (boxed int32 as int)
  kk_net_sock_t* stdio[3];         // pipes not yet taken by `kk_proc_take_stdio`
  bool     closing;                // closed by Koka; the handle itself is closed once the child exits (so it is reaped)
  bool     handle_closed;
} kk_proc_t;

static kk_proc_t* kk_proc_unbox( kk_box_t b, kk_context_t* ctx ) {
  return (kk_proc_t*)kk_cptr_unbox_borrowed(b, ctx);
}

static void kk_proc_deliver_wait( kk_proc_t* proc, kk_std_core_exn__error res, kk_context_t* ctx ) {
  if (!proc->has_wait_cb) { kk_std_core_types__result_drop(res, ctx); return; }
  kk_function_t cb = proc->wait_cb;
  proc->has_wait_cb = false;
  kk_function_call_error(cb, res, ctx);   // drops cb
}

static kk_std_core_exn__error kk_proc_exit_result( kk_proc_t* proc, kk_context_t* ctx ) {
  return kk_result_ok(kk_integer_box(kk_integer_from_int(proc->exit_code, ctx), ctx), ctx);
}

static void kk_proc_exit_cb( uv_process_t* process, int64_t exit_status, int term_signal ) {
  kk_context_t* ctx = kk_get_context();
  kk_proc_t* proc = (kk_proc_t*)process;
  proc->exited = true;
  proc->exit_code = (term_signal != 0 ? 128 + term_signal : (int32_t)exit_status);
  kk_proc_deliver_wait(proc, kk_proc_exit_result(proc, ctx), ctx);
  if (proc->closing && !proc->handle_closed) {
    proc->handle_closed = true;
    uv_close((uv_handle_t*)&proc->process, &kk_net_free_cb);
  }
}

static void kk_proc_close_proc( kk_proc_t* proc, kk_context_t* ctx ) {
  if (proc->closing) return;
  proc->closing = true;
  kk_proc_deliver_wait(proc, kk_net_closed_error(ctx), ctx);
  for (int i = 0; i < 3; i++) {
    if (proc->stdio[i] != NULL) { kk_net_close_sock(proc->stdio[i], ctx); proc->stdio[i] = NULL; }
  }
  if (proc->exited) {
    proc->handle_closed = true;
    uv_close((uv_handle_t*)&proc->process, &kk_net_free_cb);
  }
}

static char** kk_proc_cstrings( kk_vector_t v, const char* first, kk_context_t* ctx ) {
  kk_ssize_t n;
  kk_box_t* xs = kk_vector_buf_borrow(v, &n, ctx);
  kk_ssize_t extra = (first != NULL ? 1 : 0);
  char** res = (char**)kk_malloc((n + extra + 1)*kk_ssizeof(char*), ctx);
  if (first != NULL) {
    size_t len = strlen(first);
    res[0] = (char*)kk_malloc((kk_ssize_t)len + 1, ctx);
    memcpy(res[0], first, len + 1);
  }
  for (kk_ssize_t i = 0; i < n; i++) {
    kk_ssize_t len;
    const char* s = kk_string_cbuf_borrow(kk_string_unbox(xs[i]), &len, ctx);
    res[i + extra] = (char*)kk_malloc(len + 1, ctx);
    memcpy(res[i + extra], s, (size_t)len + 1);
  }
  res[n + extra] = NULL;
  return res;
}

static void kk_proc_free_cstrings( char** xs, kk_context_t* ctx ) {
  if (xs == NULL) return;
  for (char** p = xs; *p != NULL; p++) kk_free(*p, ctx);
  kk_free(xs, ctx);
}

// Start program `cmd` with `args` (without the program name), in directory
// `cwd` (if not empty), with environment `env` (`name=value` strings; inherit
// the current environment if empty). `modes` gives for stdin, stdout and
// stderr: 0 = pipe, 1 = inherit, 2 = ignore. The result is delivered right away.
kk_std_core_exn__error kk_proc_spawn_setup( kk_uv_loop_t loop, kk_string_t cmd, kk_vector_t args, kk_string_t cwd, kk_vector_t env,
                                            int32_t mode_in, int32_t mode_out, int32_t mode_err, kk_function_t cb, kk_context_t* ctx ) {
  uv_loop_t* uvloop = kk_uv_loop(loop, ctx);
  kk_proc_t* proc = (kk_proc_t*)kk_zalloc(sizeof(kk_proc_t), ctx);
  int err = (proc == NULL ? UV_ENOMEM : 0);
  int32_t modes[3] = { mode_in, mode_out, mode_err };
  uv_stdio_container_t stdio[3];
  for (int i = 0; i < 3 && err == 0; i++) {
    if (modes[i] == 0) {
      proc->stdio[i] = kk_net_pipe_alloc(uvloop, &err, ctx);
      stdio[i].flags = (uv_stdio_flags)(UV_CREATE_PIPE | (i == 0 ? UV_READABLE_PIPE : UV_WRITABLE_PIPE));
      stdio[i].data.stream = (proc->stdio[i] == NULL ? NULL : (uv_stream_t*)&proc->stdio[i]->pipe);
    }
    else if (modes[i] == 1) {
      stdio[i].flags = UV_INHERIT_FD;
      stdio[i].data.fd = i;
    }
    else {
      stdio[i].flags = UV_IGNORE;
    }
  }
  if (err == 0) {
    kk_ssize_t ncwd = 0;
    const char* ccwd = kk_string_cbuf_borrow(cwd, &ncwd, ctx);
    const char* ccmd = kk_string_cbuf_borrow(cmd, NULL, ctx);
    kk_ssize_t nenv = kk_vector_len_borrow(env, ctx);
    char** cargs = kk_proc_cstrings(args, ccmd, ctx);
    char** cenv  = (nenv > 0 ? kk_proc_cstrings(env, NULL, ctx) : NULL);
    uv_process_options_t opts;
    memset(&opts, 0, sizeof(opts));
    opts.exit_cb = &kk_proc_exit_cb;
    opts.file = ccmd;
    opts.args = cargs;
    opts.env = cenv;
    opts.cwd = (ncwd > 0 ? ccwd : NULL);
    opts.stdio_count = 3;
    opts.stdio = stdio;
    err = uv_spawn(uvloop, &proc->process, &opts);
    kk_proc_free_cstrings(cargs, ctx);
    kk_proc_free_cstrings(cenv, ctx);
  }
  kk_string_drop(cmd, ctx); kk_vector_drop(args, ctx); kk_string_drop(cwd, ctx); kk_vector_drop(env, ctx);
  if (err != 0) {
    if (proc != NULL) {
      for (int i = 0; i < 3; i++) { if (proc->stdio[i] != NULL) kk_net_close_sock(proc->stdio[i], ctx); }
      // after a failed `uv_spawn` the handle is initialized and must still be closed
      if (proc->process.loop != NULL) { proc->closing = proc->handle_closed = true; uv_close((uv_handle_t*)&proc->process, &kk_net_free_cb); }
                                 else kk_free(proc, ctx);
    }
    kk_function_drop(cb, ctx);
    return kk_error_from_uv_errno(err, ctx);
  }
  kk_function_call_error(cb, kk_result_ok(kk_cptr_box(proc, ctx), ctx), ctx);
  return kk_result_uv_handle_dispose((uv_handle_t*)NULL, NULL, &kk_uv_handle_dispose, ctx);
}

// Take the pipe for stdin (0), stdout (1) or stderr (2); `Nothing` if it is not a pipe (or already taken).
kk_std_core_types__maybe kk_proc_take_stdio( kk_box_t bproc, int32_t i, kk_context_t* ctx ) {
  kk_proc_t* proc = kk_proc_unbox(bproc, ctx);
  kk_box_drop(bproc, ctx);
  if (i < 0 || i > 2 || proc->stdio[i] == NULL) return kk_std_core_types__new_Nothing(ctx);
  kk_net_sock_t* sock = proc->stdio[i];
  proc->stdio[i] = NULL;
  return kk_std_core_types__new_Just(kk_cptr_box(sock, ctx), ctx);
}

static void kk_proc_wait_dispose( uv_handle_t* h, void* arg, kk_context_t* ctx ) {
  kk_unused(arg);
  kk_proc_t* proc = (kk_proc_t*)h;
  if (proc->has_wait_cb) {
    proc->has_wait_cb = false;
    kk_function_drop(proc->wait_cb, ctx);
  }
}

// Wait for the process to exit; delivers the exit code.
kk_std_core_exn__error kk_proc_wait_setup( kk_uv_loop_t loop, kk_box_t bproc, kk_function_t cb, kk_context_t* ctx ) {
  kk_unused(loop);
  kk_proc_t* proc = kk_proc_unbox(bproc, ctx);
  kk_box_drop(bproc, ctx);
  if (proc->exited) {
    kk_function_call_error(cb, kk_proc_exit_result(proc, ctx), ctx);
    return kk_result_uv_handle_dispose((uv_handle_t*)NULL, NULL, &kk_uv_handle_dispose, ctx);
  }
  if (proc->closing) { kk_function_drop(cb, ctx); return kk_net_closed_error(ctx); }
  if (proc->has_wait_cb) { kk_function_drop(cb, ctx); return kk_error_from_uv_errno(UV_EALREADY, ctx); }
  proc->wait_cb = cb;
  proc->has_wait_cb = true;
  return kk_result_uv_handle_dispose((uv_handle_t*)proc, NULL, &kk_proc_wait_dispose, ctx);
}

// Send a signal to the process (ignored if it already exited).
kk_unit_t kk_proc_kill( kk_box_t bproc, int32_t signum, kk_context_t* ctx ) {
  kk_proc_t* proc = kk_proc_unbox(bproc, ctx);
  kk_box_drop(bproc, ctx);
  if (!proc->exited) uv_process_kill(&proc->process, signum);
  return kk_Unit;
}

int32_t kk_proc_pid( kk_box_t bproc, kk_context_t* ctx ) {
  kk_proc_t* proc = kk_proc_unbox(bproc, ctx);
  kk_box_drop(bproc, ctx);
  return (int32_t)proc->process.pid;
}

// Release the process handle (and any pipes that were not taken); does not kill
// the process. A still running process is reaped when it exits.
kk_unit_t kk_proc_close( kk_box_t bproc, kk_context_t* ctx ) {
  kk_proc_close_proc(kk_proc_unbox(bproc, ctx), ctx);
  kk_box_drop(bproc, ctx);
  return kk_Unit;
}
