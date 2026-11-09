# Koka standard library: gap analysis and roadmap

Status as of Koka 3.3.0 (`dev` @ d23ee7cd, October 2026).

This document compares Koka's standard library (`lib/std`) with the standard
libraries of the ten most widely used general-purpose languages. It then
proposes a prioritised list of modules that would bring Koka to rough parity.

## 1. Method

**Languages compared.** The ten most widely used general-purpose languages,
taken as the consensus of TIOBE, IEEE Spectrum, RedMonk and the Stack Overflow
developer survey (2025–26):

Python · JavaScript/TypeScript (one column; same runtime library) · Java · C# · C++ · C · Go · Rust · PHP · Kotlin

Swift and Ruby were next in line. SQL, shell and HTML/CSS were left out
because they are not general-purpose languages.

**De-facto libraries.** Some languages ship small standard libraries on
purpose: C, C++ and Rust most of all, and Kotlin and JS to a lesser degree. For
these, a capability counts as covered when one library is the near-universal
default. Examples: `serde_json`, `tokio` and `rand` for Rust; libcurl, zlib and
OpenSSL for C; nlohmann/json and fmt for C++; `kotlinx.*` for Kotlin. These are
marked 📦 below. A capability is not covered when the ecosystem has no single
default.

**Exclusions.** Some modules are deprecated or removed, or their own
maintainers or communities widely regard them as mistakes or poorly
implemented. These are not counted as parity targets (see §4).

**Legend:** ✅ in the standard library · 📦 de-facto default library · ⚠️ partial or weak · ❌ absent

## 2. What Koka has today

| Area | Modules | Assessment |
|---|---|---|
| Core types | `std/core/*` (list, string, sslice, char, vector, bytes, bslice, maybe, either, result, tuple, order, exn, show) | Good functional basics; ~77 list functions. **No `sort`** (issue #610). |
| Numbers | `int` (arbitrary precision by default), `num/int32`, `num/int64`, `num/float64`, `num/ddouble` (128-bit double-double), `num/decimal`, `uint8`/`float32` as storage types | **Ahead of most languages**: bigints by default, plus decimal and double-double arithmetic. |
| Random | `num/random` (SFC PRNG, `strong-random` CSPRNG) | Adequate. |
| Time | `std/time/*` (instants, durations, calendars, time zones, leap seconds, TAI/UT1, astronomical time, formatting and parsing) | **Ahead of every language compared**, including Java's `java.time`. |
| Text | `text/regex` (PCRE2), `text/parse` (parser combinators), `text/unicode` (NFC/NFD, graphemes, width) | Good. Unicode width and grapheme handling have open bugs (#457, #458). |
| OS | `os/path` (thorough), `os/env` (read-only), `os/flags` (getopt-style CLI parsing), `os/file` (read/write *text* only), `os/dir` (list, copy, ensure-dir, is-file), `os/process` (`run-system` through the shell only), `os/readline`, `os/task` (basic parallel tasks, LVars) | **Thin.** No delete, rename, stat, binary I/O, append, stderr, exit, spawning a process with arguments, or child pipes. |
| Async | `std/async/*` (strands, channels, promises, timers, async files) | Effect-based design; libuv port in progress upstream. |
| Data structures | `data/map`, `data/set`, `data/dict`, `data/imap`, `data/iset`, `data/array` | **All six are empty `Todo` stubs** (13–15 lines each). |
| Debug | `core/debug` (trace, assert, breakpoint) | Adequate. |

Koka has implicit-parameter overloading (`?cmp`, `?show`, `?kk-file-line`).
This is the natural way to provide `?hash`, `?eq` and `?cmp` for the
collections proposed below.

### Community prior art (github.com/koka-community, unofficial)

* **`std`:** hashmap and hashset (plus mutable variants), rb-map and rb-set,
  trie, deque, heap, Okasaki structures, string builder (`stringb`), `json`,
  `sort`, `log`, a pretty printer, an ANSI printer and memoisation. Its README
  calls `linearmap`/`linearset` a "stopgap … until we have more efficient
  datastructures integrated into Koka".
* **`uv`:** libuv bindings (fs, tcp, pipe, process, signal, tty, streams).
* **`serjson`:** JSON serialisation.
* **`zlib`, `mbedtls`, `llhttp`:** C library bindings.
* **`kunit`:** unit testing.

There is no package manager yet, which is itself on the upstream roadmap.
Programs therefore can't easily depend on these community libraries, and that
is a strong argument for moving the most fundamental ones into `std`.

## 3. Comparison matrix

### Collections and algorithms

| Capability | Python | JS/TS | Java | C# | C++ | C | Go | Rust | PHP | Kotlin | **Koka** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Sort (stable, custom compare) | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ qsort | ✅ slices | ✅ | ✅ | ✅ | ❌ |
| Hash map / set | ✅ dict/set | ⚠️ Map/Set (identity keys only) | ✅ | ✅ | ✅ | 📦 glib/uthash | ✅ | ✅ | ✅ | ✅ | ❌ stub |
| Ordered (tree) map / set | ⚠️ (bisect; 📦 sortedcontainers) | 📦 | ✅ TreeMap | ✅ SortedDictionary | ✅ std::map | 📦 | ❌ (📦 google/btree) | ✅ BTreeMap | ⚠️ | ✅ (JVM) | ❌ stub |
| Hashing protocol for user types | ✅ `__hash__` | ❌ | ✅ hashCode | ✅ GetHashCode | ✅ std::hash | ❌ | ⚠️ comparable only | ✅ Hash | ⚠️ | ✅ | ❌ |
| Deque / queue | ✅ deque | ❌ | ✅ ArrayDeque | ✅ Queue | ✅ | 📦 | ❌ (container/list) | ✅ VecDeque | ✅ SplQueue | ✅ ArrayDeque | ❌ |
| Priority queue / heap | ✅ heapq | 📦 | ✅ | ✅ (.NET 6+) | ✅ | 📦 | ✅ container/heap | ✅ BinaryHeap | ✅ | ✅ (JVM) | ❌ |
| Growable mutable array | ✅ list | ✅ Array | ✅ ArrayList | ✅ List | ✅ vector | 📦 | ✅ slice | ✅ Vec | ✅ | ✅ | ⚠️ vector + local assign |
| Lazy iterators / sequences | ✅ itertools/generators | ✅ iterator helpers | ✅ Streams | ✅ LINQ | ✅ ranges | ❌ | ✅ iter (1.23) | ✅ Iterator | ✅ generators | ✅ Sequence | ⚠️ effects can do it; no library |
| Bitset | ⚠️ int | ❌ | ✅ BitSet | ✅ BitArray | ✅ bitset | ❌ | ⚠️ math/bits | 📦 | ❌ | ✅ (JVM) | ❌ |

### Text and encodings

| Capability | Python | JS/TS | Java | C# | C++ | C | Go | Rust | PHP | Kotlin | **Koka** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| String builder | ✅ join/io.StringIO | ✅ | ✅ StringBuilder | ✅ | ✅ | ⚠️ | ✅ strings.Builder | ✅ String | ✅ | ✅ buildString | ❌ (community stringb) |
| Format / interpolation | ✅ f-strings | ✅ templates | ✅ format | ✅ $"" | ✅ std::format | ✅ printf | ✅ fmt | ✅ format! | ✅ sprintf | ✅ templates | ⚠️ show, pad-left only |
| Regex | ✅ | ✅ | ✅ | ✅ | ⚠️ std::regex (excluded, §4) → 📦 RE2/PCRE2 | 📦 PCRE2 | ✅ RE2 | 📦 regex | ✅ PCRE | ✅ | ✅ PCRE2 |
| Unicode (normalise, graphemes, case) | ✅ unicodedata | ✅ Intl/Segmenter | ✅ | ✅ | 📦 ICU | 📦 ICU/utf8proc | ✅ unicode, x/text | ⚠️ 📦 unicode-* | ✅ intl/mbstring | ✅ | ⚠️ (bugs #457, #458) |
| UTF-8 ⇄ bytes with error handling | ✅ | ✅ TextEncoder | ✅ | ✅ | ⚠️ | ❌ | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| Base64 / hex | ✅ | ✅ | ✅ | ✅ | 📦 | 📦 | ✅ | 📦 base64/hex | ✅ | ✅ | ❌ |
| Parser combinators | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | 📦 nom | ❌ | ❌ | ✅ **ahead** |
| Pretty printer (Wadler-style) | ⚠️ pprint | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | 📦 | ❌ | ❌ | ❌ (community pprint) |

### Data formats

| Capability | Python | JS/TS | Java | C# | C++ | C | Go | Rust | PHP | Kotlin | **Koka** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| JSON | ✅ | ✅ | 📦 Jackson | ✅ System.Text.Json | 📦 nlohmann | 📦 cJSON/jansson | ✅ | 📦 serde_json | ✅ | 📦 kotlinx.serialization | ❌ (community json/serjson) |
| CSV | ✅ | 📦 csv-parse | 📦 | 📦 CsvHelper | 📦 | 📦 | ✅ | 📦 csv | ✅ | 📦 | ❌ |
| TOML (config) | ✅ tomllib (read) | 📦 | 📦 | 📦 | 📦 toml++ | 📦 | 📦 | 📦 toml | ❌ | 📦 | ❌ |
| XML | ✅ | ⚠️ DOMParser (browser) | ✅ | ✅ | 📦 pugixml | 📦 libxml2 | ✅ | 📦 quick-xml | ✅ | ✅ (JVM) | ❌ |
| UUID | ✅ | ✅ randomUUID | ✅ | ✅ Guid | 📦 | 📦 | 📦 google/uuid | 📦 uuid | 📦 ramsey/uuid | ✅ kotlin.uuid | ❌ |
| Generic serialisation (derive) | ⚠️ dataclasses | ❌ | ⚠️ (excluded, §4) | ✅ | ❌ | ❌ | ✅ struct tags | 📦 serde | ⚠️ | 📦 kotlinx.serialization | ❌ (needs language support) |

### OS, I/O and processes

| Capability | Python | JS/TS | Java | C# | C++ | C | Go | Rust | PHP | Kotlin | **Koka** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| File read/write (binary, append, streaming) | ✅ | ✅ fs | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ text, whole-file only |
| File metadata, delete, rename, permissions | ✅ | ✅ | ✅ | ✅ | ✅ filesystem | ⚠️ POSIX | ✅ | ✅ | ✅ | ✅ | ❌ |
| Directory walk / glob / temp files | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ POSIX | ✅ | ⚠️ 📦 walkdir/tempfile | ✅ | ✅ | ⚠️ list/copy, tempdir |
| Paths | ✅ pathlib | ✅ path | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |
| stdin / stdout / stderr streams | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ stdout and readline only |
| Process spawn (args, pipes, exit code) | ✅ subprocess | ✅ child_process | ✅ ProcessBuilder | ✅ | 📦 Boost.Process | ⚠️ POSIX spawn | ✅ os/exec | ✅ | ✅ proc_open | ✅ (JVM) | ⚠️ shell string only |
| Exit code, signals, set env | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ (env is read-only) |
| CLI argument parsing | ✅ argparse | ✅ parseArgs | 📦 picocli | 📦 System.CommandLine | 📦 CLI11 | ⚠️ getopt | ✅ flag | 📦 clap | ⚠️ getopt | 📦 clikt | ✅ os/flags |

### Networking and security

| Capability | Python | JS/TS | Java | C# | C++ | C | Go | Rust | PHP | Kotlin | **Koka** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| URL parse / query encode | ✅ | ✅ URL | ✅ URI | ✅ Uri | 📦 | 📦 | ✅ net/url | 📦 url | ✅ | ✅ (JVM) | ❌ |
| TCP / UDP sockets | ✅ | ✅ net/dgram | ✅ | ✅ | 📦 Asio | ✅ BSD sockets | ✅ | ✅ | ✅ | ✅ (JVM) | ❌ (community uv) |
| TLS | ✅ ssl | ✅ tls | ✅ | ✅ SslStream | 📦 OpenSSL | 📦 OpenSSL | ✅ crypto/tls | 📦 rustls | ✅ | ✅ (JVM) | ❌ (community mbedtls) |
| HTTP client | ✅ urllib (📦 requests) | ✅ fetch | ✅ HttpClient | ✅ HttpClient | 📦 libcurl | 📦 libcurl | ✅ | 📦 reqwest | ✅ curl ext | 📦 ktor-client | ❌ |
| HTTP server | ⚠️ http.server (dev) | ✅ http | ⚠️ jdk.httpserver | ✅ Kestrel | 📦 Beast | 📦 | ✅ net/http | 📦 axum/hyper | ✅ (SAPI) | 📦 ktor | ❌ |
| Crypto hashes, HMAC | ✅ hashlib | ✅ crypto | ✅ MessageDigest | ✅ | 📦 OpenSSL | 📦 OpenSSL | ✅ | 📦 RustCrypto | ✅ | ✅ (JVM) | ❌ |
| Secure random | ✅ secrets | ✅ | ✅ | ✅ | ⚠️ random_device | ❌ | ✅ | 📦 rand/getrandom | ✅ | ✅ | ✅ strong-random |
| Compression (gzip/deflate, zip) | ✅ | ✅ zlib | ✅ | ✅ | 📦 zlib | 📦 zlib | ✅ | 📦 flate2 | ✅ | ✅ (JVM) | ❌ (community zlib) |

### Concurrency

| Capability | Python | JS/TS | Java | C# | C++ | C | Go | Rust | PHP | Kotlin | **Koka** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Async I/O runtime | ✅ asyncio | ✅ event loop | ✅ virtual threads | ✅ async/await | 📦 Asio | 📦 libuv | ✅ goroutines | 📦 tokio | ⚠️ Fibers (📦 Amp) | 📦 kotlinx.coroutines | ⚠️ in progress (libuv) |
| Threads / tasks | ✅ | ✅ workers | ✅ | ✅ | ✅ | ✅ C11/pthreads | ✅ | ✅ | ❌ | ✅ | ⚠️ basic `task`/`parallel` |
| Mutex, atomics, channels | ✅ | ⚠️ Atomics | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ⚠️ async channels only |
| Timers, sleep | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ async wait |

### Numbers and time

| Capability | Python | JS/TS | Java | C# | C++ | C | Go | Rust | PHP | Kotlin | **Koka** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Big integers | ✅ | ✅ BigInt | ✅ | ✅ | 📦 GMP/Boost | 📦 GMP | ✅ math/big | 📦 num-bigint | ✅ gmp | ✅ (JVM) | ✅ default `int` |
| Decimal | ✅ | ❌ | ✅ BigDecimal | ✅ decimal | 📦 | 📦 | ⚠️ | 📦 rust_decimal | ✅ bcmath | ✅ (JVM) | ✅ |
| Rationals / complex | ✅ fractions | ❌ | ❌ | ✅ Complex | ✅ complex | ✅ complex.h | ✅ big.Rat, complex128 | 📦 num | ❌ | ❌ | ❌ |
| Statistics / math helpers | ✅ statistics, math | ✅ Math | ✅ Math | ✅ Math | ✅ cmath | ✅ math.h | ✅ math | ✅ f64 methods | ✅ | ✅ | ✅ float64 math |
| Date/time and time zones | ✅ zoneinfo | ⚠️ Date → Temporal | ✅ java.time | ✅ | ✅ chrono (C++20) | ⚠️ time.h | ✅ | ⚠️ 📦 chrono/jiff | ✅ | 📦 kotlinx-datetime | ✅ **ahead** |

### Developer tooling

| Capability | Python | JS/TS | Java | C# | C++ | C | Go | Rust | PHP | Kotlin | **Koka** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Unit testing | ✅ unittest (📦 pytest) | ✅ node:test | 📦 JUnit | 📦 xUnit | 📦 GoogleTest | 📦 | ✅ testing | ✅ #[test] | 📦 PHPUnit | ✅ kotlin.test | ❌ (community kunit) |
| Logging | ✅ logging | ⚠️ console (📦 pino) | 📦 SLF4J | ✅ ILogger | 📦 spdlog | ⚠️ syslog | ✅ log/slog | 📦 log/tracing | 📦 Monolog | 📦 | ❌ (community log) |
| Embedded SQL database | ✅ sqlite3 | ⚠️ node:sqlite (new) | ✅ JDBC (driver 📦) | 📦 Microsoft.Data.Sqlite | 📦 | 📦 sqlite | ✅ database/sql (driver 📦) | 📦 rusqlite | ✅ PDO | 📦 | ❌ |

### Rough tally

Koka is fully at parity in 10 of the 50 capabilities, and partial in about 15 more. It is ahead of
the field in time, numeric towers and parser combinators, and effects give it a
uniquely clean async and generator story. It is weakest in exactly the areas
every other language treats as table stakes:

1. collections (including `sort`)
2. file and process I/O
3. encodings and data formats
4. networking
5. testing and logging

## 4. Excluded: modules their own communities regret

These were not used as parity targets.

| Language | Excluded | Reason |
|---|---|---|
| Python | `asyncore`, `asynchat`, `smtpd`, `cgi`, `cgitb`, `telnetlib`, `nntplib`, `imp`, `distutils`, audio modules, etc. | The "dead batteries" ([PEP 594](https://peps.python.org/pep-0594/)), removed in 3.12–3.13. |
| Java | `java.util.Date` and `Calendar`; `Vector`, `Hashtable` and `Stack`; Java object serialisation; `SecurityManager`; CORBA, RMI and applets; `java.util.logging` (in practice) | Superseded by `java.time` and the generic collections. Brian Goetz has called serialisation a "horrible mistake". The rest were removed or deprecated for removal. |
| C# | `BinaryFormatter`, non-generic `ArrayList`/`Hashtable`, `WebClient`/`HttpWebRequest`, Remoting | Removed (.NET 9) or obsolete. |
| JS / Node | `Date` (being replaced by Temporal); `url.parse`, `querystring`, `domain`, `punycode` | Legacy or deprecated in Node. |
| C++ | `std::regex`; `std::auto_ptr`; `vector<bool>`; `std::valarray`; `<codecvt>`/`wstring_convert`; `std::rand` | `std::regex` is widely considered too slow to use, and the ABI freezes it that way. The rest are removed, deprecated or widely avoided. |
| C | `gets`; `strtok`; locale-dependent `<ctype.h>` behaviour | `gets` was removed in C11; `strtok` is not reentrant. |
| Go | `container/list` and `container/ring` (rarely useful, per the Go team); `net/rpc`, `net/smtp`, `log/syslog` and `syscall` (frozen); `io/ioutil` (deprecated); `plugin` | Frozen or deprecated. |
| PHP | `mysql_*`, `ereg`, `mcrypt`, `create_function`, `each()`; SPL data structures (in practice) | Removed. SPL structures are generally avoided in favour of `ext-ds`. |
| Rust | `LinkedList` (officially discouraged in its own docs) | Discouraged by the docs themselves. |

**Lessons that inform the roadmap below:**

* Don't ship mutable non-generic collections, linked lists or a toy HTTP
  server.
* Make the time API immutable and zone-aware. Koka already does this.
* Don't ship an implicit, reflection-based binary serialisation format.
* Don't ship a regex engine that's too slow to use. Koka's choice of PCRE2 is
  sound.
* Freeze rather than grow protocol-specific clients (SMTP, NNTP, telnet). Koka
  shouldn't add these at all.

## 5. Recommended modules

Priority reflects (a) how many of the ten languages provide the capability in
std or as a near-universal default, and (b) how much else depends on it.

Every module with externs needs **both a C and a JS implementation**. CI only
tests these two backends, and the C# backend is broken (§6), so it can be
ignored.

### Tier 0: foundations (blocking almost everything else)

| # | Module | Contents | Notes and prior art |
|---|---|---|---|
| 1 | `std/core/list` + `std/core/vector`: **sort** | Stable merge sort (`sort`, `sort-by`, `sort-on`) using `?cmp`; vector sort; `binary-search`; `dedup`; `group-by` | Upstream issue #610 (and #591). Pure Koka, FBIP-friendly. Community `std/data/sort`. **Best first PR.** |
| 2 | `std/core/hash` | `hash` overloadable through an implicit `?hash` parameter; instances for primitives, strings, lists, tuples, maybe/either; `combine`; a seeded fast hash (wyhash or SipHash-1-3) in C and JS | Prerequisite for hash maps, sets and memoisation. Community `std/data/hash`. |
| 3 | `std/data/map`, `std/data/set` (fill the stubs) | Persistent ordered map and set keyed by `?cmp` (weight-balanced or red-black tree): insert, lookup, delete, union, intersect, diff, fold, range queries, min/max, `to-list`/`from-list` | Stubs already exist upstream. Community `rb-map` and `rb-set`. Koka's FBIP makes in-place updates of uniquely-owned trees cheap. |
| 4 | `std/data/hashmap`, `std/data/hashset` (or fill `dict`) | Persistent HAMT keyed by `?hash` + `?eq`, with the same API shape as map | Community `hashmap`, `hashset`. |
| 5 | `std/data/imap`, `std/data/iset` (fill the stubs) | Int-keyed Patricia trees (as in Haskell's IntMap) | Stubs already exist. |
| 6 | `std/data/array` (fill the stub) | Growable mutable array (push, pop, set, slice, iterate) under a `st<h>` heap effect, plus `freeze` to vector | Upstream roadmap item: "improve performance of array/mutable reference programming". Coordinate with maintainers. |
| 7 | `std/data/deque`, `std/data/heap` | Persistent deque (Okasaki/finger tree); persistent priority queue (pairing or leftist heap) | Community `deque`, `heap`, `okasaki/*`. |
| 8 | `std/core/seq` (or `std/data/iter`) | Lazy sequences and generators built on effects (`yield`); combinators such as map, filter, take, zip, chunk, window and enumerate; consuming from lists, vectors, maps and file lines | An idiomatic Koka strength. It also gives every collection one shared traversal API. |

### Tier 1: everyday programs (scripts, CLIs, tools)

| # | Module | Contents | Notes |
|---|---|---|---|
| 9 | `std/text/builder` | Efficient string builder (append, append-char, `to-string`) | Community `stringb`. |
| 10 | `std/text/format` | `format("{} has {:>8.2}", ...)`-style formatting; width, alignment and precision; integer bases | Every language has this. It could use `?show`. Check what `std/time/format` already provides. |
| 11 | `std/text/encoding` | UTF-8 encode/decode with errors (bytes ⇄ string), base64 (standard and URL-safe), hex, percent-encoding | Builds on `core/bytes`. Related upstream issue #418 (bytes). |
| 12 | `std/os/file` (extend) | Binary read/write, append, streaming file handles, `exists`, `remove`, `rename`, `metadata`/stat (size, mtime, permissions), `set-permissions`, temp files, symlinks | Biggest OS gap. Async variants live in `std/async/os/file`. |
| 13 | `std/os/dir` (extend) | `create-dir(-all)`, `remove-dir(-all)`, `walk` (lazy, through `seq`), `glob` | |
| 14 | `std/os/io` | stdin as a stream or lines, `eprint`/`eprintln` (stderr), `flush`, `is-tty` | Today only stdout and `readline` exist. |
| 15 | `std/os/process` (extend) | Spawn with an argv list (no shell), environment and cwd, stdin/stdout/stderr pipes, wait or exit status, kill; `exit(code)` | Community `uv/process` is the async route. |
| 16 | `std/os/env` (extend), `std/os/signal` | `set-env`, `unset-env`; signal handlers as an effect | |
| 17 | `std/data/json` | JSON value type, parser with error positions, serialiser, pretty printer, a `?to-json`/`?from-json` implicit-instance convention | Community `std/data/json` and `serjson`. Ergonomics depend on derive support (§6). |
| 18 | `std/test` | Test effect: `test`, `expect`, `expect-eq`, grouping, a runner with summary and exit code; optional property testing using `num/random` | Go, Rust, Python and Kotlin ship this in std. Community `kunit`. |
| 19 | `std/log` | Levelled, structured logging as an effect (handler decides sink and format) | Go's `log/slog` is the model. Community `std/log`. |

### Tier 2: networked and production programs

| # | Module | Contents | Notes |
|---|---|---|---|
| 20 | `std/crypto/hash` | SHA-256/512, SHA-1 (for legacy use only), BLAKE2b/BLAKE3, HMAC; constant-time compare | C: vendor a small audited implementation, or use mbedtls. JS: `node:crypto` / WebCrypto. |
| 21 | `std/compress` | deflate, zlib, gzip (stream and one-shot); zip read/write later | Community `zlib`. |
| 22 | `std/net/url` | RFC 3986 parse and build, query-string encode and decode, resolve relative URLs | Pure Koka. |
| 22b | `std/net/hpack` | ✅ HPACK header compression (RFC 7541): decoder with the dynamic table and Huffman strings, stateless encoder; tables generated from the RFC, tested with all examples of its appendix C |
| 23 | `std/net/tcp`, `std/net/udp`, `std/net/dns` | Async sockets on the libuv event loop | Community `uv` (tcp, pipe, stream). **Coordinate with the upstream libuv `std/async` port.** |
| 24 | `std/net/tls` | Client and server TLS over the socket stream | Community `mbedtls`. JS: `node:tls`. |
| 25 | `std/net/http` | HTTP/1.1 client (first) and a minimal production-capable server; request/response types; headers; chunked transfer | Community `llhttp` parser. Go's `net/http` is the model of "server good enough for production". Do **not** ship a toy dev-only server (§4). |
| 26 | `std/io/stream` | Reader and writer effects (byte and text), buffering, line splitting, connecting files, processes, sockets and compression | Should be designed before #12, #15, #21 and #23 so that they share one I/O abstraction. |
| 27 | `std/os/sync` | Atomic refs, mutex, thread-safe channels for `std/os/task` | Upstream roadmap: "parallel task support is very basic; we need a great work-stealing thread pool". This is runtime work; coordinate. |

### Tier 3: parity polish

| # | Module | Contents | Notes |
|---|---|---|---|
| 28 | `std/data/csv` | RFC 4180 reader and writer, streaming | Python, Go and PHP ship this. |
| 29 | `std/data/toml` | Parse and serialise (config files) | Python ships a reader (`tomllib`). Everyone else uses a de-facto library. |
| 30 | `std/data/uuid` | v4 (random) and v7 (time-ordered); parse and show | Uses `strong-random` and `std/time`. |
| 31 | `std/num/rational`, `std/num/complex` | Exact rationals over `int`; complex `float64` | Cheap to add, given bigints. |
| 32 | `std/data/bitset` | Dense bitset over `bytes` or int64 words | |
| 33 | `std/text/pretty` | Wadler/Leijen pretty printer | Already in the Haskell compiler. Community `std/pretty`. |
| 34 | `std/text/unicode` (fix and extend) | Fix #457 (emoji width) and #458 (grapheme iteration); add case folding and word segmentation | |
| 35 | `std/db/sqlite` | SQLite binding | Optional. Python and PHP ship one; most others rely on a library. |
| 36 | `std/data/xml` | Pull parser and minimal DOM | Optional and declining in importance. Last priority. |

**Deliberately not proposed:**

* GUI toolkits.
* Email, SMTP, FTP or telnet clients.
* Mutable non-generic collections, or a linked-list type beyond the built-in
  list.
* Binary object serialisation.
* Templating engines.
* Audio and image codecs.

These are deprecated across the comparison set, or they belong in packages.

## 6. Blockers and design questions to raise upstream first

1. **The data-structure stubs are upstream's own `Todo`s.** Daan Leijen likely
   has views on representation (FBIP-friendly trees, `?cmp` versus explicit
   comparators). Open a GitHub discussion before writing #3–#6.
2. **No deriving or reflection.** JSON, hashing, equality and `show` for
   user-defined types need either hand-written implicit instances or
   compiler-generated ones. The README already lists "generate show / (==) for
   datatypes" as an LSP task. A small derive mechanism would make #2, #17 and
   #29 far more pleasant.
3. **No package manager.** This is the reason to fold proven community
   libraries into `std` rather than leaving them separate.
4. **I/O abstraction.** Agree on `std/io/stream` (#26) and how it relates to
   the libuv async port before extending files, processes and sockets.
   Otherwise there will be two incompatible stacks.
5. **Backends.** Each extern needs both C and JS implementations. For JS,
   decide whether Node, the browser or both are in scope (issue #778). The C#
   backend (`--target=cs`) is non-functional: codegen crashes on struct
   matching, and the generated code doesn't compile under Mono `csc`. It only
   supports the legacy `csc` command line from .NET Framework 4.x or Mono, not
   the modern `dotnet` SDK. Treat it as out of scope.
6. **Mutable fields.** The upstream roadmap notes these are needed for optimal
   B-trees. That affects the long-term representation for #3.

## 7. Suggested first contributions

Small, self-contained and unblocked:

1. `sort` for list and vector (#1). It closes issue #610.
2. `std/text/encoding`: base64, hex and UTF-8 (#11).
3. `std/os/file` and `std/os/dir` extensions (#12, #13), plus `eprintln` and
   `exit` (#14, #15).
4. `std/core/hash` (#2), then propose map, set and hashmap (#3, #4) in a design
   discussion.
5. `std/test` (#18), so that every later module ships with tests in Koka
   itself.

## 8. Implementation status (this fork)

Everything below works on both the C and JavaScript (Node) backends. Each
item has a test in `test/lib/` that passes under the official test harness
(`cabal run koka-test`). `util/dev/kt.sh <test.kk>` runs a test on both
backends and diffs the output against its `.out` file.

| # | Module | Status |
|---|---|---|
| 1 | `std/core/list` sort | ✅ `sort`, `sort-by`, `sort-on`, `sort-desc`, `is-sorted`, `merge`, `dedup`, `group`, `group-by`, `vector/sort` (stable natural merge sort) |
| 2 | `std/data/hash` | ✅ MurmurHash3-based `?hash`; deterministic and identical on C and JS |
| 3 | `std/data/map`, `std/data/set` | ✅ Weight-balanced persistent trees: lookup, insert, remove, alter, union, intersection, difference, split, range queries, `elem-at` |
| 4 | `std/data/hashmap`, `std/data/hashset` | ✅ Hash buckets in a `map<int,_>` (not a HAMT yet) |
| 5 | `std/data/imap`, `iset`, `dict` | ✅ As aliases of `map<int,_>`, `set<int>` and `map<string,_>` (not Patricia trees) |
| 6 | `std/data/array` | ✅ Mutable growable `array<h,a>` under `st<h>` (use with `run` to stay pure): `push`/`pop` (amortized O(1), doubling), `get`/`set`/`a[i]`/`at`/`modify`, `insert`/`remove-at`, `swap`, `reserve`, `extend`, `clear`, `reverse`, `sort` (stable), `map-in-place`, `foreach(-indexed)`, `foldl`, `find-index`, copying `list`/`vector`/`slice`; updates are in place on both backends (the storage vector is never shared; JS bypasses the copying `kk_ref_vector_assign_borrow`). Reads skip the `hdiv` check, so an array of self-referencing closures could tie a knot without `div` |
| 7 | `std/data/deque`, `std/data/heap` | ✅ Banker's deque; pairing heap |
| 8 | `std/core/seq` | ✅ Lazy, pull-based `seq<e,a>` (like OCaml `Seq.t`) and generators (`generate { ... yield(x) ... }`, built from escaping resumptions); `count-from`, `range`, `iterate`, `unfold`, `repeat(edly)`, `cycle`; conversion from lists, vectors, strings and `maybe`; lazy `map`, `filter`, `filter-map`, `take(-while)`, `drop(-while)`, `step-by`, `++`, `concat`, `flat-map`, `zip(-with)`, `indexed`, `scan`, `chunk`, `window`, `intersperse`, `dedup`, `tap`; consumers `list`, `vector`, `foldl`, `foreach`, `find`, `any`/`all`, `length`, `at`, `last`, `sum`, `minimum`/`maximum`, `split-at`, `uncons`, `show`. Not imported by `std/core`. Lazy `seq` conversions for `map`/`set` (plus `seq-from` for ordered ranges), `hashmap`, `hashset`, `deque` and `heap` (ascending), and a lazy directory `walk` in `std/os/fs` |
| 9 | `std/text/builder` | ✅ `builder` value plus a `build { emit(..) }` effect |
| 10 | `std/text/format` | ✅ `format("{} {:>8} {0:*^9}", args)` |
| 11 | `std/text/encoding` | ✅ base64 (standard and URL-safe), hex, percent-encoding. UTF-8 was already in `core/bytes` |
| 12–13 | `std/os/fs` | ✅ Binary read/write/append, `read-lines`, `file-info`, `path-exists`, `remove-file`, `rename`, `set-permissions`, `create-dir`, `remove-dir(-all)`, `set-cwd`, temp files and directories, `glob`, lazy `walk` (sorted, depth first, with `prune`, `max-depth` and `follow-symlinks`), file handles (`open-file`, `with-file` with `Read`/`Write`/`Append`, `read`, `write`, `close` (idempotent; a forgotten handle is closed by its finalizer on C), `stream`), `write-stream`, `append-stream` |
| 14 | `std/os/io` | ✅ `eprint(ln)`, `flush`, `read-stdin(-lines)`, `stdin-stream` and `read-stdin-chunk` (incremental, as input arrives), `write-stdout`/`write-stderr` (bytes), `*-is-tty`, `exit` |
| 15 | `std/os/process` | ✅ `run`, `run-bytes`, `run-output` (argv, stdin, cwd, env; captures exit code, stdout and stderr) |
| 15b | `std/async/os/process` | ✅ Asynchronous child processes: `spawn` with piped, inherited or ignored stdio, `write-stdin`, `close-stdin`, `read-stdout`/`read-stderr`, `wait`, `kill`, `pid`; `run-process(-bytes,-output)` capture output without blocking other strands, and a cancelled run (e.g. by `timeout`) kills the child |
| 16 | `std/os/env` | ✅ `set-env`, `unset-env`; signals in `std/async/os/signal`: `wait-signal([SIGINT, SIGTERM])` (for graceful shutdown with `firstof`), `raise-signal`, `number`, on libuv (C) and Node `process` events (JS); cancellable · ❌ persistent handlers (the default action applies between two `wait-signal` calls), signals on Windows beyond `SIGINT`/`SIGTERM`/`SIGBREAK` |
| 17 | `std/data/json` | ✅ Parse (with line/column errors), compact and pretty output, accessors, `?json` encoding |
| 18 | `std/test` | ✅ `run-tests`, `group`, `test`, `expect*`, `check-property` with generators |
| 19 | `std/log` | ✅ `log` effect; stderr text/JSON, collect and ignore handlers; `with-log-fields` |
| 20 | `std/crypto/hash` | ✅ SHA-256, SHA-1, HMAC, constant-time compare; BLAKE2b and BLAKE2s (RFC 7693, keyed, any output size) and BLAKE3 (any output length, keyed, key derivation), in C and JS, checked against Python `hashlib` and `b3sum` |
| 21 | `std/compress` | ✅ zlib on C, Node `zlib` on JS: `compress`/`decompress` for raw deflate, zlib and gzip (`Auto` detects gzip or zlib on decompression), `gzip`/`gunzip`/`deflate`/`inflate`, levels 0–9; the same on byte streams (`s.gunzip.lines`), incrementally on C (on JS the stream functions collect the input first, since Node has no synchronous incremental zlib); multi-member gzip; `crc32` and `adler32` with incremental `init`; interoperates with the `gzip` tool; zip archives in `std/compress/zip` (`zip-read`, `zip-find`, `zip-write`: stored and deflated entries, CRC-32 checked, directories, UTF-8 names, Unix permissions, reproducible output; read and written by the `zip`/`unzip` tools) · ❌ zip64, encrypted zips, brotli, zstd |
| 22 | `std/net/url` | ✅ Parse and show, query parameters, RFC 3986 `resolve` |
| 23 | `std/async/os/net` | ✅ TCP on libuv (C) and Node (JS): `resolve-host`, `tcp-connect`, `read`, `read-all`, `write-all`, `shutdown-write`, `tcp-listen`, `accept`, `serve`, addresses, `set-nodelay`; cancellable |
| 23b | `std/async/os/udp` | ✅ UDP on libuv (C) and `dgram` (JS): `udp-bind`, `send-to` (IP or host name), `receive-from` with the sender address, `set-broadcast`, `local-address`; multicast (`join-multicast`/`leave-multicast` with an optional interface, `set-multicast-ttl`, `set-multicast-loop`, `set-multicast-interface`); cancellable · ❌ connected UDP sockets |
| 24 | `std/async/os/tls` | ✅ TLS client: `tls-connect` with certificate and host name verification (system CA bundle, `SSL_CERT_FILE`, or an explicit `ca`); TLS server: `tls-server-config` (PEM certificate chain and key) and `tls-accept` on accepted connections; client certificates (`cert`/`key` on the client, `client-ca` and `client-cert-required` on the server, `peer-certificate`); ALPN (`alpn`, `alpn-protocol`); mbedtls as an in-memory engine on C, `node:tls` on JS; `net-stream` unifies plain and TLS connections; SNI: the server picks a certificate by the requested name (`sni` with names and `*.domain` patterns), and the client can ask for a `server-name` other than the host it connects to · ❌ certificate revocation |
| 25 | `std/async/os/http` | ✅ HTTP/1.1 and HTTP/2 client and server for `http` and `https` (`http-get`/`post`/`request`, `http-serve` with keep-alive and an optional TLS config); Content-Length, chunked and read-to-close bodies; the client follows redirects (`max-redirects`, browser-style method rewriting, credentials dropped across origins) and accepts a custom CA and a client certificate (`tls-ca`, `tls-cert`, `tls-key`); `http-client` reuses keep-alive connections (per-host idle pool with an idle timeout that also respects the server's `Keep-Alive: timeout`, idempotent requests retried once on a stale connection); the server reports the client address (`peer`) and certificate (`client-cert`) and honours `Connection: close` from a handler, and closes connections that stay idle (`idle-timeout`, announced in `Keep-Alive`) or send a request too slowly (`request-timeout`, answered with 408); HTTP/2 (`std/async/os/http2`) with ALPN on `https` and with prior knowledge (`h2c`) on `http`: multiplexing, flow control, `version` on requests and responses; the client shares one connection per origin (also between concurrent first requests) and retries requests refused by a closing server; interoperates with curl/nghttp2, Node.js, Google, Cloudflare and GitHub; compression: the client asks for gzip/deflate and decodes the body unless the caller sets `Accept-Encoding` (also zlib-or-raw "deflate" and stacked encodings), the server compresses text responses for clients that accept gzip with `http-serve(..., compress = True)` or `gzip-response` (with `Vary`, honouring `q=0`) · ❌ streaming request and response bodies (bodies are `bytes`), server push, the `Upgrade: h2c` mechanism, HTTP/3 |
| 26 | `std/io/stream` | ✅ `byte-stream<e>`: a lazy `seq<e,bytes>` of chunks, pull-based and pure Koka (no mutable state). Sources `bytes/stream`, `string/stream`, `from-reader`; lazy `lines` (`\n` and `\r\n`), `split-bytes`, `decode-utf8` (characters split over chunks), `encode-utf8`, `unlines`, `rechunk`, `take-bytes`, `drop-bytes`; `read-all`, `read-text`, `byte-count`, `pipe`; incremental `read-line`, `read-until` (with `max-len`), `read-bytes`, which return the rest of the stream. Connected to sync file handles (`std/os/fs`), stdin (`std/os/io`), TCP sockets, TLS connections, child process output and async files. Constant memory: 300 MB of lines in 1.7 s with 3.4 MB resident · ❌ compression transformers (#21), write buffering beyond `rechunk`; `std/async/os/http` keeps its own reader |
| 27 | `std/os/sync` | ✅ `spawn`/`join` run `<ndet,console,div>` functions on the `std/os/task` thread pool; `atomic` 64-bit integers (`load`, `store`, `add`, `fetch-add`, `exchange`, `compare-exchange`), `shared<a>` cells (`read`, `write`, atomic `update`), `mutex` with `with-lock`, blocking `channel` (unbounded or with a `capacity`; `send` waits while it is full, `try-send`, `receive`, `try-receive`, `count`), `has-threads`; stored values are marked thread-shared. POSIX threads on C (checked: an unlocked read-modify-write loses updates, the locked one does not; the test passes 30 of 30 runs, also at `-O1`); `with-lock` releases the lock also on an exception; on JS everything runs sequentially and blocking on nothing raises a deadlock error · ❌ a work-stealing scheduler, condition variables |
| 28 | `std/data/csv` | ✅ |
| 29 | `std/data/toml` | ✅ TOML 1.0 `parse-toml` with line/column errors: all string forms (basic, literal, multi-line with line-ending backslash and extra quotes), integers (hex/octal/binary, underscores, arbitrary precision), floats (`inf`, `nan`), the four date/time kinds (validated, kept as RFC 3339 text), arrays, inline tables, dotted keys, `[tables]` and `[[arrays of tables]]` with the redefinition rules; accessors (`at`, `path`, `as-*`), `==`, `stringify` that parses back to the same document, conversion to JSON |
| 30 | `std/data/uuid` | ✅ v4 and v7, parse and show |
| 31 | `std/num/rational`, `std/num/complex` | ✅ Rationals over `int` in lowest terms: arithmetic (`x/0` is 0, as for `int`), `^` with negative powers, comparisons, `floor`/`ceiling`/`truncate`/`round` (half to even), exact conversion from `float64` and nearest conversion back, `show-decimal`, `parse-rational` (`n/d` and decimals). Complex `float64`: arithmetic (Smith's division), `abs`, `arg`, `conj`, `polar`, `exp`, `ln`, `sqrt` (principal, signed zeros), `pow`, integer `^`, `sin`/`cos`/`tan`, `show` |
| 32 | `std/data/bitset` | ✅ Persistent dense bitset in 64-bit words: `bitset(list)` (linear after sorting), `range-bitset`, `member`, `insert`/`remove` (copying), `+` (union), `-`, `intersection`, `sym-difference`, `complement`, `is-subset`/`is-disjoint`, `count` (popcount), `minimum`/`maximum`/`next-member` (ctz/clz), `list`, `seq`, `foldl`, `filter`, `==`, `show` |
| 33 | `std/text/pretty` | ✅ Wadler/Leijen pretty printer (strict renderer): `text`, `line`, `linebreak`, `softline`, `hardline`, `++`, `<+>`, `<->`, `group`, `nest`, `align`, `hang`, `indent`, `column`, `nesting`, `fill`, `fill-break`, `hsep`/`vsep`/`sep`, `hcat`/`vcat`/`cat`, `fill-sep`/`fill-cat`, `punctuate`, `enclose-sep`, `list-doc`, `tupled`, `semi-braces`, `block`, `parens` etc., `pretty(width)` |
| 34 | `std/text/unicode` | ✅ Tables generated from the UCD 17.0 (`util/gen-unicode-tables.py`, decoded on first use): `graphemes` (UAX #29 extended grapheme clusters, incl. emoji ZWJ sequences, flags and Indic conjuncts; fixes #458), `word-segments`/`words` (UAX #29 word boundaries), grapheme-aware `width` (emoji, flags and presentation selectors are 2 columns; fixes #457), `fold-case` and `equals-ignore-case` (full case folding), `normalize` NFC/NFD/NFKC/NFKD in Koka (it was a no-op on C). Passes the official GraphemeBreakTest (766/766), WordBreakTest (1944/1944) and a NormalizationTest sample (3631/3631) on C and JS. `graphemes` no longer normalizes its input |
| 35 | `std/db/sqlite` | ✅ System `sqlite3` on C (the flake adds it), `node:sqlite` on JS: `open-database`/`with-database` (files and `:memory:`), `exec` (scripts), `execute` and `query`/`query-each`/`query-one`/`query-value` with `?` parameters bound as `sql-value`s (`SqlNull`, `SqlInt` up to 64 bits, `SqlFloat`, `SqlText`, `SqlBlob`; `.sql` conversions incl. `maybe` and `bool`), rows by column name (`int`, `text`, `float`, `blob`, `is-null`), `last-insert-rowid`, `transaction` (rolled back on an exception), errors with SQLite's message, parameter count checked |
| 36 | `std/data/xml` | ✅ Pure Koka: `xml-events` (a lazy pull parser over `seq`) and `parse-xml` (elements, text, CDATA, comments, processing instructions), well-formedness checks with line/column errors (matching tags, one root, unique attributes, `<` in attributes, `--` in comments), the predefined entities and character references, attribute whitespace normalization, BOM, XML declaration and DOCTYPE skipped; `attr`, `elements`, `child`, `find-all`, `text-content`; `stringify` with optional indentation and escaping; namespaces (`parse-xml(s, namespaces = True)`/`expand-namespaces` give `{uri}local` names, with default namespaces, `xmlns=""`, the `xml:` prefix, and errors for undeclared prefixes; `namespace-uri`, `local-name`, `elements-ns`) · ❌ DTD entities, validation |

### Platform limitations

* The new C file-system and process primitives are POSIX only. On Windows they
  return `ENOSYS`.
* The JavaScript implementations need Node.js. In a browser they report an
  error.

### Upstream issues found along the way

* `std/os/file` on the JS backend called `$std_core_exn.Ok`, which does not
  exist, so `read-text-file` and `write-text-file` always failed. Fixed here.
* `std/os/dir` and `std/os/process` had no JS implementation at all. Added
  here.
* `"/".path.string` is `"."`: the root directory is lost by `std/os/path`.
  Not fixed.
* At `-O1`, an inlined `char/hash('x')` (defined as `c.int.hash`) evaluated as
  if the character were `0`. This looks like a compiler bug in inlining or
  constant folding around `int32` conversions. It is worked around with
  `noinline` in `std/data/hash`. To reproduce, revert that and run
  `test/lib/hash1.kk` through `cabal run koka-test -- --match /lib/hash1/`.
* When a `firstof` or `timeout` canceled a strand that contained a nested
  `interleaved`, the nested strands were abandoned without running their
  finalizers: the interleaving loop's own `receive` was canceled first, and
  the strands' cancelations were left on its channel. For example, a server
  built on `serve` leaked the open connections when it was canceled. Fixed
  in `std/async/interleave` (test: `test/async/interleave-finally.kk`); this
  also affects upstream with PR #955.
* **JavaScript backend miscompiled self tail calls** whose arguments are other
  parameters: the loop assigned the parameters one by one, so
  `f(b, a, n - 1)` became `a = b; b = a` and `go(xs, i + 1, i)` read the
  already incremented `i`. Found through the HPACK encoder. Fixed in
  `Backend/JavaScript/FromCore.hs` (`genOverride` copies such arguments
  first); test: `test/jsgen/tailcall-args.kk`.
* Closing a libuv socket twice was a use-after-free on the C backend (its
  memory is released after the first close completes), and
  `std/async/os/process` did that for stdin (`close-stdin`, then `close`).
  It crashed only in optimized builds, depending on memory reuse. Sockets
  now carry a `closed` flag, so `close` is idempotent.
* The libuv bindings did not ignore `SIGPIPE`, so writing to a closed socket
  or to a child that exited killed the whole program on the C backend (Node
  ignores it). The networking and process bindings now ignore it.
* The modules added in this fork were missing from `lib/toc.kk`, which the
  test harness compiles before running tests in parallel. Tests then compiled
  them concurrently into one build directory, which occasionally truncated a
  `.kki` file and failed a random test. They are listed now.
* Koka does not rebuild a module when only its `extern import` C file
  changes; touch the `.kk` file to force it.
* Type inference crashed with `internal error: no empty iconstraints` (an
  unsolved `hdiv` constraint) on `!r` for a `ref<global,list<t>>` read
  inside `async-ioc`, where `t` is a struct holding an `any`. Annotating the
  ref did not help. The workaround is a top-level helper with an explicit
  `<read<global>,div>` signature (`read-idle` in `std/async/os/http`).
* **The `-O1` specializer can loop forever.** A lazy `filter` written as
  `Seq(fn() match s.skip-while(fn(x) !pred(x)) ... filter(rest, pred))` hangs
  the compiler (after type checking) at `-O1` for a call such as
  `range(1,5).filter(is-odd)`; it compiles instantly with `-O0`. Moving all
  recursion into one helper (`filter-step` in `std/core/seq`) avoids it.
* **Internal error `Core.Core.splitTForall: Expected forall`** for a top-level
  function whose effect row tail `e` appears only in its result effect and
  which performs a handled effect (`walk-dir` in `std/os/fs`, declared
  `<yield<path>,fsys,exn,div|e> ()`). A closed row works, since closed
  function types are opened at call sites.
* `koka -o <absolute path>` fails with "could not find module".
* On the JS backend, `bytes.subbytes(start, len)` called `slice(start, len)`,
  but `slice` takes an end index, so any slice with `start > 0` was wrong.
  `kk_bytes_substring` also returned `[]` instead of `""`. Fixed here.
* Several JS files returned `$std_core_types._Unit_`, which does not exist; the
  correct name is `$std_core_types.Unit`. Fixed here.
* Koka only links static C libraries (`lib<name>.a`) and only searches fixed
  paths. The flake builds static libuv and pcre2 and sets
  `KOKA_OPTIONS=--cclibdir=...`. Upstream PR #795 (pkg-config lookup) would
  help.
* The upstream async PRs #924 (repeating libuv callbacks) and #955 (fixes for
  `firstof` exceptions, cancellation scopes, and canceled channel receives)
  are applied in this fork.

* **Effect handlers inside parallel tasks corrupted memory** (fixed in this
  fork). A `try`/`throw` or `finally` inside a `std/os/task` task crashed most
  runs on the C backend ("mimalloc: corrupted free list entry"). Values
  created at startup are shared by all threads but had plain (non-atomic)
  reference counts: string literals (`string.h` allocates them on the heap,
  the static variant is `#if 0`), top-level values such as handler tags, and
  the empty evidence vector. Fix: `kk_init_string_literal` marks literals as
  thread shared, the C backend marks every heap-allocated top-level value as
  shared after initializing it, and the empty evidence vector is the static
  block `kk_evv_empty_static` (stuck reference count). Eight tasks each
  running 50 000 `finally`/`try` blocks now pass 40 of 40 runs (debug and `-O2`).
* **Externs with ten or more arguments were miscompiled** (fixed in this fork,
  C and JS backends). In an external template, `#10` was read as `#1`
  followed by `0`, so the tenth argument became the first one with a `0`
  appended (`evloop0`). Indices now take the longest run of digits that is a
  valid argument number (`test/cgen/extern-args`).
* **Exponential code size for long boolean chains** (fixed in this fork). A
  function that is one `||` chain of `&&` clauses generated C code that doubled
  with every clause (10 clauses: 14 MB of C, 20 minutes in clang). The
  simplifier's case-of-case rule pushed the outer `case` into all inner
  branches when the other inner branches simplify, but those still copy the
  selected outer branch, which for `(a && b) || rest` is `rest`. It now also
  requires the copied outer branches to be small (`maxCaseOfCaseCopy`): the 10
  clauses give 16 KB of C and compile in a second (`test/cgen/bool-chain`).

### Koka language gotchas hit while writing these modules

* **Mutual recursion fails the termination checker.** Either add
  `pretend-decreasing`, or give the functions the `div` effect and wrap the
  public entry point in `pretend-no-div`.
* **A polymorphic effect row can't be widened inside a function.** For example,
  `fun test(body : () -> <exn|e> ()) : <testing|e> ()` cannot call
  `report(..., catch(.., body))`. Write the body as `<exn,testing|e>`.
  Handlers that re-emit their own effect need `<eff,eff|e>`.
* **Constructors generate predicates.** `Empty` gives `is-empty` and `Symlink`
  gives `is-symlink`, which clash with functions of the same name.
* **Reserved words:** `exists`, `prefix` and `try` are keywords.
* **Shadowing:** parameters named `all`, `default`, `fields` or `after` shadow
  functions of the same name and give confusing type errors.
* **Effectful guards aren't allowed.** Pattern guards must be total.
* **`mask<exn>{ ... }` widens an effect row.** Wrapping a `catch` in it gives
  the result an extra `exn`, so it can sit next to code that may throw (for
  example both branches of `interleaved`).
* **More reserved words:** `handle`, `handler`, `raw`, `context`, `mask` and `prefix` are keywords, and `|` cannot be defined as an operator.
* **Scoped `with x = f()` covers the rest of the block,** so a resource opened
  that way stays open until the block ends.
* **Effect rows inside data types are invariant.** A `seq<<div>,int>` forced in
  `main` gives the closed row `<div,div>`, which neither absorbs into `ioc` nor
  widens. Data that holds effectful functions should put `div` (or whatever
  it always needs) inside the type and keep the user's row open (`seq<e,int>`).
* **A function value with a bare effect variable can't run in a wider row.**
  Inside a `<div|e>` function, calling an `a -> e b` parameter fails ("effects
  do not match"); type such parameters as `a -> <div|e> b`.
* **Recursion inside a closure still counts.** `fun map(s, f) = Seq(fn() ...
  map(rest, f))` is flagged as divergent; lazy constructors need
  `pretend-decreasing` on the recursive argument. An optional parameter
  (`n : int = 0`) on the recursive function defeats `pretend-decreasing`; recurse
  through a helper without one.
* **Modules under `std/core/` don't implicitly import `std/core`.** A new module
  there must `import std/core` itself.
* **Fixity declarations go at the top of a module,** before any other
  declaration; defining a new `(++)` without `pub infixr 60 (++)` makes chains
  of `++` ambiguous.
* **`std/core` already has a type `stream<a>`** (an unused co-inductive
  infinite list), so a new `stream` type is ambiguous everywhere; the byte
  stream alias is `byte-stream<e>`.
* **An effect can't be added on top of a data type's effect.** A function that
  takes `seq<e,a>` and throws can't be `<exn,div|e>`: forcing the sequence
  only gives `<div|e>`, and the two don't unify. Ask for the effect in the type
  instead (`seq<<exn|e>,a>`).
* **`unsafe-total` around a call that needs a handler crashes at run time.**
  Wrapping an `exn`-typed extern in `unsafe-total` compiles, but the call then
  looks for exception evidence that isn't there (a segfault on C, "reading
  'hnd'" on JS). Type stateful externs as `ndet`, which needs no handler, and
  hide it with `unsafe-total` or `pretend-no-ndet`.
* **A C library found only as a `.dylib` needs `syslib`.** `library="z"` looks
  for a static library to copy into the build and fails for nix's zlib;
  `syslib="z"` just links `-lz`.
* **Editing only an inline `.c`/`.js` file does not rebuild the module.** The
  build cache keys on the `.kk` file, so touch it after changing its inline
  code, or the old code keeps running.
* **Reading a `ref` of a polymorphic type adds `div`.** `!r` with
  `r : ref<h,vector<a>>` has the `hdiv` constraint, so it is divergent for any
  `a` that could mention the heap. Library code that controls what is stored
  can read through an extern typed `read<h>`.
* **A definition's own name shadows its overloads in its body.** Inside
  `pub fun list( a : array<h,a> )`, `list(0, n)` is a recursive call (and
  fails or diverges), not `std/core/list/list`.
* **A local `val` shadows functions of the same name for dot calls.**
  `val (lines, code) = ...` makes a later `s.lines` refer to the tuple.
