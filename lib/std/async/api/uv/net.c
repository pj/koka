/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

// TCP networking on libuv.
//
// A socket (or server) is a `kk_net_sock_t` boxed as an opaque C pointer; it
// must be closed explicitly with `kk_net_close`. Pending asynchronous
// operations store their Koka callback in the socket itself (not in the uv
// handle `data` field) so a socket can have a pending read and a pending
// write at the same time.

#include <uv.h>
#include <string.h>

typedef struct kk_net_sock_s {
  uv_tcp_t tcp;                    // must be first: we cast between `uv_tcp_t*`, `uv_stream_t*`, and `kk_net_sock_t*`
  bool     has_read_cb;
  kk_function_t read_cb;           // pending read: `error<bytes> -> ioc ()`
  bool     has_conn_cb;
  kk_function_t conn_cb;           // pending wait-for-connection (servers): `error<()> -> ioc ()`
  struct kk_net_sock_s* queue;     // accepted connections that were not yet taken (servers)
  struct kk_net_sock_s* next;      // link in the accept queue
  int      listen_err;             // last error reported to the connection callback (servers)
  bool     closing;
} kk_net_sock_t;

static kk_net_sock_t* kk_net_sock_alloc( uv_loop_t* loop, int* err, kk_context_t* ctx ) {
  kk_net_sock_t* sock = (kk_net_sock_t*)kk_zalloc(sizeof(kk_net_sock_t), ctx);
  if (sock == NULL) { *err = UV_ENOMEM; return NULL; }
  *err = uv_tcp_init(loop, &sock->tcp);
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
