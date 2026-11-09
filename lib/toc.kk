/*---------------------------------------------------------------------------
  Copyright 2012-2024, Microsoft Research, Daan Leijen.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/*
This is the main index of the standard Koka libraries.

See the [Koka book](book.html) for further information on the Koka language.
*/
module toc

pub import std/core/types
pub import std/core/unsafe
pub import std/core/undiv
pub import std/core
pub import std/core/seq

pub import std/os/env
pub import std/os/flags
pub import std/os/file
pub import std/os/dir
pub import std/os/path
pub import std/os/process
pub import std/os/readline
pub import std/os/task
pub import std/os/fs
pub import std/os/io
pub import std/io/stream
pub import std/compress

pub import std/text/parse
pub import std/text/regex
pub import std/text/unicode
pub import std/text/builder
pub import std/text/encoding
pub import std/text/format
pub import std/text/pretty

pub import std/data/map
pub import std/data/set
pub import std/data/hash
pub import std/data/hashmap
pub import std/data/hashset
pub import std/data/imap
pub import std/data/iset
pub import std/data/dict
pub import std/data/deque
pub import std/data/heap
pub import std/data/json
pub import std/data/toml
pub import std/data/bitset
pub import std/db/sqlite
pub import std/data/csv
pub import std/data/uuid

pub import std/net/url
pub import std/net/hpack
pub import std/crypto/hash
pub import std/log
pub import std/test

pub import std/num/int32
pub import std/num/int64
pub import std/num/float64
pub import std/num/decimal
pub import std/num/ddouble
pub import std/num/random
pub import std/num/rational
pub import std/num/complex

pub import std/time
pub import std/time/timestamp
pub import std/time/astro
// pub import std/time/download
// pub import std/time/timezone
// pub import std/time/ut1

pub import std/async
pub import std/async/async
pub import std/async/channel
pub import std/async/interleave
pub import std/async/os/file
pub import std/async/os/net
pub import std/async/os/tls
pub import std/async/os/http2
pub import std/async/os/http
pub import std/async/os/process
pub import std/async/os/signal
pub import std/async/os/udp

pub fun main()
  println("toc")