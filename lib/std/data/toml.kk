/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* TOML documents (TOML 1.0): parsing, accessing and writing.

   ```
   import std/data/toml

   fun main()
     val config = parse-toml(r#"
       title = "example"
       [server]
       host = "localhost"
       ports = [8080, 8081]
       [[users]]
       name = "ada"
       [[users]]
       name = "bob"
     "#)
     println(config.path(["server", "host"]).as-string)        // Just("localhost")
     println(config.at("users").as-array.map(fn(us) us.length)) // Just(2)
     println(config.stringify)
   ```

   Tables keep the order of their keys. Dates and times are kept as text in
   their RFC 3339 form, together with their kind (see `:datetime-kind`).
   Integers have arbitrary precision (TOML only guarantees 64 bits).
*/
module std/data/toml

import std/core/undiv
import std/num/float64
import std/text/builder
import std/data/json

// The kind of a TOML date or time.
pub type datetime-kind
  // A date and time with an offset, like `1979-05-27T07:32:00Z`.
  Offset-datetime
  // A date and time without an offset, like `1979-05-27T07:32:00`.
  Local-datetime
  // A date, like `1979-05-27`.
  Local-date
  // A time of day, like `07:32:00`.
  Local-time

pub fun datetime-kind/(==)( a : datetime-kind, b : datetime-kind ) : bool
  match (a, b)
    (Offset-datetime, Offset-datetime) -> True
    (Local-datetime, Local-datetime) -> True
    (Local-date, Local-date) -> True
    (Local-time, Local-time) -> True
    _ -> False

pub fun datetime-kind/show( k : datetime-kind ) : string
  match k
    Offset-datetime -> "offset-datetime"
    Local-datetime -> "local-datetime"
    Local-date -> "local-date"
    Local-time -> "local-time"

// A TOML value. A document is a `TTable`.
pub type toml
  TString( s : string )
  TInt( i : int )
  TFloat( f : float64 )
  TBool( b : bool )
  TDatetime( kind : datetime-kind, text : string )
  TArray( items : list<toml> )
  TTable( fields : list<(string, toml)> )

// ----------------------------------------------------------------------------
// Access
// ----------------------------------------------------------------------------

// The value of `key` in a table, if it is there.
pub fun field( t : toml, key : string ) : maybe<toml>
  match t
    TTable(fs) -> fs.lookup(fn(k) k == key)
    _ -> Nothing

// The value of `key` in a table, or an empty table if it is not there (so
// that accesses can be chained).
pub fun at( t : toml, key : string ) : toml
  t.field(key).default(TTable([]))

// Follow a path of keys through nested tables.
pub fun path( t : toml, keys : list<string> ) : toml
  keys.foldl(t, at)

// The value of `key`; raises an exception if it is not there.
pub fun @index( t : toml, key : string ) : exn toml
  match t.field(key)
    Just(v) -> v
    Nothing -> throw("toml: no key " ++ key.show)

pub fun as-string( t : toml ) : maybe<string>
  match t
    TString(s) -> Just(s)
    _ -> Nothing

pub fun as-int( t : toml ) : maybe<int>
  match t
    TInt(i) -> Just(i)
    _ -> Nothing

// Integers are also converted to `:float64`.
pub fun as-float( t : toml ) : maybe<float64>
  match t
    TFloat(f) -> Just(f)
    TInt(i) -> Just(i.float64)
    _ -> Nothing

pub fun as-bool( t : toml ) : maybe<bool>
  match t
    TBool(b) -> Just(b)
    _ -> Nothing

// The text of a date or time (in RFC 3339 form, with `T` and `Z` in upper case).
pub fun as-datetime( t : toml ) : maybe<string>
  match t
    TDatetime(_, s) -> Just(s)
    _ -> Nothing

// The kind of a date or time.
pub fun as-datetime-kind( t : toml ) : maybe<datetime-kind>
  match t
    TDatetime(k, _) -> Just(k)
    _ -> Nothing

pub fun as-array( t : toml ) : maybe<list<toml>>
  match t
    TArray(xs) -> Just(xs)
    _ -> Nothing

pub fun as-table( t : toml ) : maybe<list<(string, toml)>>
  match t
    TTable(fs) -> Just(fs)
    _ -> Nothing

// The keys of a table (empty for other values).
pub fun keys( t : toml ) : list<string>
  match t
    TTable(fs) -> fs.map(fst)
    _ -> []

pub fun (==)( a : toml, b : toml ) : bool
  match (a, b)
    (TString(x), TString(y)) -> x == y
    (TInt(x), TInt(y)) -> x == y
    (TFloat(x), TFloat(y)) -> x == y || (x.is-nan && y.is-nan)
    (TBool(x), TBool(y)) -> x == y
    (TDatetime(k1, x), TDatetime(k2, y)) -> k1 == k2 && x == y
    (TArray(xs), TArray(ys)) -> xs.length == ys.length && zipwith(xs, ys, fn(x, y) pretend-decreasing(x) == y).all(id)
    (TTable(xs), TTable(ys)) ->
      xs.length == ys.length && xs.all fn((k, x))
        match ys.lookup(fn(k2) k2 == k)
          Just(y) -> pretend-decreasing(x) == y
          Nothing -> False
    _ -> False

pub fun (!=)( a : toml, b : toml ) : bool
  !(a == b)

// Convert to JSON: dates and times become strings, and non-finite floats
// become the strings `"inf"`, `"-inf"` and `"nan"`.
pub fun toml/json( t : toml ) : json
  match t
    TString(s) -> JString(s)
    TInt(i) -> JInt(i)
    TFloat(f) -> if f.is-finite then JFloat(f) else JString(f.float-text)
    TBool(b) -> JBool(b)
    TDatetime(_, s) -> JString(s)
    TArray(xs) -> JArray(xs.map(fn(x) pretend-decreasing(x).json))
    TTable(fs) -> JObject(fs.map(fn((k, v)) (k, pretend-decreasing(v).json)))

// ----------------------------------------------------------------------------
// Writing
// ----------------------------------------------------------------------------

// Write a table as a TOML document. Nested tables become `[sections]` and
// arrays of tables `[[sections]]`.
pub fun stringify( t : toml ) : string
  match t
    TTable(fs) -> pretend-no-div { build { emit-table([], fs) } }
    _ -> t.value-text

pub fun show( t : toml ) : string
  t.value-text

fun is-table( t : toml ) : bool
  match t
    TTable(_) -> True
    _ -> False

fun is-table-array( t : toml ) : bool
  match t
    TArray(xs) -> !xs.is-empty && xs.all(is-table)
    _ -> False

fun emit-table( path : list<string>, fs : list<(string, toml)> ) : <emit,div> ()
  // plain keys first, then sub-tables and arrays of tables
  fs.foreach fn((k, v))
    if !v.is-table && !v.is-table-array then emit(k.key-text ++ " = " ++ v.value-text ++ "\n")
  fs.foreach fn((k, v))
    val p = path ++ [k]
    match v
      TTable(sub) ->
        // a table with only sub-tables needs no header of its own
        if sub.is-empty || sub.any(fn((_, x)) !x.is-table && !x.is-table-array) then
          emit("\n[" ++ p.map(key-text).join(".") ++ "]\n")
        emit-table(p, sub)
      TArray(xs) | v.is-table-array ->
        xs.foreach fn(x)
          emit("\n[[" ++ p.map(key-text).join(".") ++ "]]\n")
          emit-table(p, x.as-table.default([]))
      _ -> ()

fun is-bare-key-char( c : char ) : bool
  c.is-alpha-num || c == '_' || c == '-'

fun key-text( k : string ) : string
  if !k.is-empty && k.list.all(is-bare-key-char) then k else k.toml-quote

fun float-text( f : float64 ) : string
  if f.is-nan then "nan"
  elif f.is-posinf then "inf"
  elif f.is-neginf then "-inf"
  elif f == f.truncate && f.abs < 1.0e15 then f.int.show ++ ".0"
  else
    val s = shortest-show(f, 1)
    if s.list.any(fn(c) c == '.' || c == 'e' || c == 'E') then s else s ++ ".0"

// the shortest representation that parses back to exactly the same number
fun shortest-show( f : float64, prec : int ) : string
  val s = f.show(0 - prec)
  if prec >= 17 || parse-float64(s) == Just(f) then s
  else shortest-show(f, pretend-decreasing(prec + 1))

fun value-text( t : toml ) : string
  match t
    TString(s) -> s.toml-quote
    TInt(i) -> i.show
    TFloat(f) -> f.float-text
    TBool(b) -> if b then "true" else "false"
    TDatetime(_, s) -> s
    TArray(xs) -> "[" ++ xs.map(fn(x) pretend-decreasing(x).value-text).join(", ") ++ "]"
    TTable(fs) -> if fs.is-empty then "{}" else "{ " ++ fs.map(fn((k, v)) k.key-text ++ " = " ++ pretend-decreasing(v).value-text).join(", ") ++ " }"

// Quote a string as a TOML basic string.
pub fun toml-quote( s : string ) : string
  "\"" ++ s.list.map(escape-char).join ++ "\""

fun escape-char( c : char ) : string
  match c
    '"' -> "\\\""
    '\\' -> "\\\\"
    '\n' -> "\\n"
    '\t' -> "\\t"
    '\r' -> "\\r"
    _ | c.int == 8 -> "\\b"
    _ | c.int == 12 -> "\\f"
    _ | c.int < 0x20 || c.int == 0x7F -> "\\u" ++ c.int.show-hex(4, use-capitals = True, pre = "")
    _ -> c.string

// ----------------------------------------------------------------------------
// Parsing
// ----------------------------------------------------------------------------

// Parse a TOML document. Raises an exception with the line and column on an
// error, including keys or tables that are defined twice.
pub fun parse-toml( s : string ) : exn toml
  val cs = s.list
  pretend-no-div { cs.parse-document(cs, Doc(NTable([], Header), [], False)) }.root.freeze

// Parse a TOML document, returning `Nothing` on an error.
pub fun try-parse-toml( s : string ) : maybe<toml>
  catch(fn(_) Nothing, { Just(parse-toml(s)) })

fun parse-error( src : list<char>, rest : list<char>, msg : string ) : exn a
  val consumed = src.take(src.length - rest.length)
  val line = consumed.filter(fn(c) c == '\n').length + 1
  val col = consumed.reverse.take-while(fn(c) c != '\n').length + 1
  throw("toml parse error at line " ++ line.show ++ ", column " ++ col.show ++ ": " ++ msg)

// How a table came to exist: defined by a `[header]`, created implicitly by a
// longer header (`[a.b]` creates `a`), created by a dotted key (`a.b = 1`),
// or written inline (`a = { b = 1 }`, which cannot be extended).
type origin
  Header
  Implicit
  Dotted
  Inline

// The document while it is parsed.
type node
  NVal( v : toml )
  NTable( fields : list<(string, node)>, origin : origin )
  NTables( tables : list<node> )   // an array of tables, in reverse

struct doc
  root : node
  current : list<string>   // the table that key/value pairs go into
  in-array : bool          // `current` was opened with `[[...]]`

fun freeze( n : node ) : toml
  match n
    NVal(v) -> v
    NTable(fs, _) -> TTable(fs.map(fn((k, x)) (k, pretend-decreasing(x).freeze)))
    NTables(ts) -> TArray(ts.reverse.map(fn(t) pretend-decreasing(t).freeze))

fun is-ws( c : char ) : bool
  c == ' ' || c == '\t'

fun skip-ws( cs : list<char> ) : list<char>
  match cs
    Cons(c, cc) | c.is-ws -> skip-ws(cc)
    _ -> cs

// Skip whitespace, comments and newlines (inside arrays).
fun skip-ws-nl( src : list<char>, cs : list<char> ) : <div,exn> list<char>
  match cs.skip-ws
    Cons('\n', rest) -> src.skip-ws-nl(rest)
    Cons('\r', Cons('\n', rest)) -> src.skip-ws-nl(rest)
    Cons('#', rest) -> src.skip-ws-nl(pretend-decreasing(src.skip-comment(rest)))
    rest -> rest

// Skip a comment up to (not including) the end of the line.
fun skip-comment( src : list<char>, cs : list<char> ) : exn list<char>
  match cs
    Cons('\n', _) -> cs
    Cons('\r', Cons('\n', _)) -> cs
    Cons(c, rest) ->
      if (c.int < 0x20 && c != '\t') || c.int == 0x7F then src.parse-error(cs, "control character in a comment")
      else src.skip-comment(rest)
    Nil -> cs

// The end of a line: whitespace, an optional comment, and a newline (or the end).
fun end-of-line( src : list<char>, cs : list<char> ) : exn list<char>
  val rest = match cs.skip-ws
    Cons('#', r) -> src.skip-comment(r)
    r -> r
  match rest
    Nil -> Nil
    Cons('\n', r) -> r
    Cons('\r', Cons('\n', r)) -> r
    _ -> src.parse-error(rest, "expected the end of the line")

fun parse-document( src : list<char>, cs : list<char>, d : doc ) : <div,exn> doc
  match cs.skip-ws
    Nil -> d
    Cons('\n', rest) -> src.parse-document(rest, d)
    Cons('\r', Cons('\n', rest)) -> src.parse-document(rest, d)
    Cons('#', rest) -> src.parse-document(src.end-of-line(src.skip-comment(rest)), d)
    Cons('[', Cons('[', rest)) ->
      val (key, rest1) = src.parse-key(rest.skip-ws)
      match rest1.skip-ws
        Cons(']', Cons(']', rest2)) ->
          val root = src.add-table-array(rest, d.root, key)
          src.parse-document(src.end-of-line(rest2), Doc(root, key, True))
        r -> src.parse-error(r, "expected ']]'")
    Cons('[', rest) ->
      val (key, rest1) = src.parse-key(rest.skip-ws)
      match rest1.skip-ws
        Cons(']', rest2) ->
          val root = src.define-table(rest, d.root, key)
          src.parse-document(src.end-of-line(rest2), Doc(root, key, False))
        r -> src.parse-error(r, "expected ']'")
    line ->
      val (key, v, rest) = src.parse-key-value(line)
      val root = src.set-key(line, d.root, d.current, key, v)
      src.parse-document(src.end-of-line(rest), d(root = root))

fun parse-key-value( src : list<char>, cs : list<char> ) : <div,exn> (list<string>, node, list<char>)
  val (key, rest1) = src.parse-key(cs)
  match rest1.skip-ws
    Cons('=', rest2) ->
      val (v, rest3) = src.parse-value(rest2.skip-ws)
      (key, v, rest3)
    r -> src.parse-error(r, "expected '='")

// A key: simple keys separated by dots.
fun parse-key( src : list<char>, cs : list<char> ) : exn (list<string>, list<char>)
  val (k, rest) = src.parse-simple-key(cs)
  match rest.skip-ws
    Cons('.', rest1) ->
      val (ks, rest2) = src.parse-key(pretend-decreasing(rest1.skip-ws))
      (Cons(k, ks), rest2)
    _ -> ([k], rest)

fun parse-simple-key( src : list<char>, cs : list<char> ) : exn (string, list<char>)
  match cs
    Cons('"', Cons('"', Cons('"', _))) -> src.parse-error(cs, "a key cannot be a multi-line string")
    Cons('\'', Cons('\'', Cons('\'', _))) -> src.parse-error(cs, "a key cannot be a multi-line string")
    Cons('"', rest) -> src.parse-basic-string(rest, [])
    Cons('\'', rest) -> src.parse-literal-string(rest, [])
    _ ->
      val bare = cs.take-while(is-bare-key-char)
      if bare.is-empty then src.parse-error(cs, "expected a key")
      (bare.string, cs.drop(bare.length))

// ----------------------------------------------------------------------------
// Building the document
// ----------------------------------------------------------------------------

// Update the field `key` of a table's fields with `f` (which gets the
// current value, if any).
fun update-field( fs : list<(string, node)>, key : string, f : maybe<node> -> <div,exn> node ) : <div,exn> list<(string, node)>
  match fs.lookup(fn(k) k == key)
    Nothing -> fs ++ [(key, f(Nothing))]
    Just(old) -> fs.map(fn((k, x)) if k == key then (k, f(Just(old))) else (k, x))

// Go into the table at `path` (through the last table of arrays of tables),
// creating implicit tables as needed, and update it with `f`.
fun at-table( src : list<char>, at : list<char>, n : node, path : list<string>, f : node -> <div,exn> node ) : <div,exn> node
  match path
    Nil -> f(n)
    Cons(k, ks) -> match n
      NTable(fs, o) ->
        val fs' = fs.update-field(k) fn(old)
          match old
            Nothing -> src.at-table(at, NTable([], Implicit), ks, f)
            Just(NTables(Cons(t, ts))) -> NTables(Cons(src.at-table(at, t, ks, f), ts))
            Just(sub) -> match sub
              NTable(_, o2) ->
                if o2.is-inline then src.parse-error(at, "cannot extend the inline table " ++ k.show)
                else src.at-table(at, sub, ks, f)
              _ -> src.parse-error(at, "the key " ++ k.show ++ " is not a table")
        NTable(fs', o)
      _ -> src.parse-error(at, "the key " ++ k.show ++ " is not a table")

fun is-dotted-table( n : node ) : bool
  match n
    NTable(_, Dotted) -> True
    _ -> False

// `[path]`
fun define-table( src : list<char>, at : list<char>, root : node, path : list<string> ) : <div,exn> node
  val parent = path.init
  val key = path.last.default("")
  src.at-table(at, root, parent) fn(t)
    match t
      NTable(fs, o) ->
        val fs' = fs.update-field(key) fn(old)
          match old
            Nothing -> NTable([], Header)
            Just(NTable(sub, Implicit)) -> NTable(sub, Header)
            Just(_) -> src.parse-error(at, "the table " ++ path.join(".").show ++ " is defined twice")
        NTable(fs', o)
      _ -> src.parse-error(at, "not a table")

// `[[path]]`
fun add-table-array( src : list<char>, at : list<char>, root : node, path : list<string> ) : <div,exn> node
  val parent = path.init
  val key = path.last.default("")
  src.at-table(at, root, parent) fn(t)
    match t
      NTable(fs, o) ->
        val fs' = fs.update-field(key) fn(old)
          match old
            Nothing -> NTables([NTable([], Header)])
            Just(NTables(ts)) -> NTables(Cons(NTable([], Header), ts))
            Just(_) -> src.parse-error(at, "the key " ++ path.join(".").show ++ " is not an array of tables")
        NTable(fs', o)
      _ -> src.parse-error(at, "not a table")

// `key = value` in the table `current`.
fun set-key( src : list<char>, at : list<char>, root : node, current : list<string>, key : list<string>, v : node ) : <div,exn> node
  src.at-table(at, root, current, fn(t) src.set-dotted(at, t, key, v))

fun set-dotted( src : list<char>, at : list<char>, t : node, key : list<string>, v : node ) : <div,exn> node
  match t
    NTable(fs, o) -> match key
      [k] ->
        val fs' = fs.update-field(k) fn(old)
          match old
            Nothing -> v
            Just(_) -> src.parse-error(at, "the key " ++ k.show ++ " is defined twice")
        NTable(fs', o)
      Cons(k, ks) ->
        val fs' = fs.update-field(k) fn(old)
          match old
            Nothing -> src.set-dotted(at, NTable([], Dotted), ks, v)
            Just(sub) | sub.is-dotted-table -> src.set-dotted(at, sub, ks, v)
            Just(_) -> src.parse-error(at, "the key " ++ k.show ++ " is already defined")
        NTable(fs', o)
      Nil -> t
    _ -> src.parse-error(at, "not a table")

// ----------------------------------------------------------------------------
// Values
// ----------------------------------------------------------------------------

fun parse-value( src : list<char>, cs : list<char> ) : <div,exn> (node, list<char>)
  match cs
    Cons('"', Cons('"', Cons('"', rest))) ->
      val (s, rest1) = src.parse-ml-basic(src.skip-first-newline(rest), [])
      (NVal(TString(s)), rest1)
    Cons('\'', Cons('\'', Cons('\'', rest))) ->
      val (s, rest1) = src.parse-ml-literal(src.skip-first-newline(rest), [])
      (NVal(TString(s)), rest1)
    Cons('"', rest) ->
      val (s, rest1) = src.parse-basic-string(rest, [])
      (NVal(TString(s)), rest1)
    Cons('\'', rest) ->
      val (s, rest1) = src.parse-literal-string(rest, [])
      (NVal(TString(s)), rest1)
    Cons('[', rest) -> src.parse-array(src.skip-ws-nl(rest), [])
    Cons('{', rest) -> src.parse-inline-table(rest.skip-ws, NTable([], Inline), True)
    _ ->
      val word = cs.take-while(fn(c) c.is-alpha-num || c == '_' || c == '-' || c == '+' || c == '.' || c == ':')
      match word.string
        "true" -> (NVal(TBool(True)), cs.drop(4))
        "false" -> (NVal(TBool(False)), cs.drop(5))
        _ -> src.parse-number-or-date(cs)

fun skip-first-newline( src : list<char>, cs : list<char> ) : list<char>
  match cs
    Cons('\n', rest) -> rest
    Cons('\r', Cons('\n', rest)) -> rest
    _ -> cs

fun parse-array( src : list<char>, cs : list<char>, acc : list<toml> ) : <div,exn> (node, list<char>)
  match cs
    Cons(']', rest) -> (NVal(TArray(acc.reverse)), rest)
    _ ->
      val (v, rest) = src.parse-value(cs)
      match src.skip-ws-nl(rest)
        Cons(',', rest1) -> src.parse-array(pretend-decreasing(src.skip-ws-nl(rest1)), Cons(v.freeze, acc))
        Cons(']', rest1) -> (NVal(TArray(Cons(v.freeze, acc).reverse)), rest1)
        r -> src.parse-error(r, "expected ',' or ']' in an array")

fun parse-inline-table( src : list<char>, cs : list<char>, t : node, first : bool ) : <div,exn> (node, list<char>)
  match cs
    Cons('}', rest) | first -> (NVal(t.freeze), rest)
    _ ->
      val (key, v, rest) = src.parse-key-value(cs)
      val t' = src.set-dotted(cs, t, key, v)
      match rest.skip-ws
        Cons(',', rest1) -> src.parse-inline-table(pretend-decreasing(rest1.skip-ws), t', False)
        Cons('}', rest1) -> (NVal(t'.freeze), rest1)
        r -> src.parse-error(r, "expected ',' or '}' in an inline table")

fun is-toml-control( c : char ) : bool
  (c.int < 0x20 && c != '\t') || c.int == 0x7F

fun parse-basic-string( src : list<char>, cs : list<char>, acc : list<char> ) : exn (string, list<char>)
  match cs
    Cons('"', rest) -> (acc.reverse.string, rest)
    Cons('\\', rest) ->
      val (c, rest1) = src.parse-escape(rest)
      src.parse-basic-string(pretend-decreasing(rest1), Cons(c, acc))
    Cons('\n', _) -> src.parse-error(cs, "newline in a string")
    Cons(c, rest) ->
      if c.is-toml-control then src.parse-error(cs, "control character in a string")
      else src.parse-basic-string(rest, Cons(c, acc))
    Nil -> src.parse-error(cs, "unterminated string")

fun parse-escape( src : list<char>, cs : list<char> ) : exn (char, list<char>)
  match cs
    Cons('"', rest) -> ('"', rest)
    Cons('\\', rest) -> ('\\', rest)
    Cons('b', rest) -> (8.char, rest)
    Cons('t', rest) -> ('\t', rest)
    Cons('n', rest) -> ('\n', rest)
    Cons('f', rest) -> (12.char, rest)
    Cons('r', rest) -> ('\r', rest)
    Cons('u', rest) -> src.parse-unicode(rest, 4)
    Cons('U', rest) -> src.parse-unicode(rest, 8)
    _ -> src.parse-error(cs, "invalid escape")

fun parse-unicode( src : list<char>, cs : list<char>, n : int ) : exn (char, list<char>)
  val ds = cs.take(n)
  if ds.length != n || !ds.all(is-hex-digit) then src.parse-error(cs, "invalid unicode escape")
  match parse-int(ds.string, hex = True)
    Just(i) | (i >= 0 && i < 0xD800) || (i > 0xDFFF && i <= 0x10FFFF) -> (i.char, cs.drop(n))
    _ -> src.parse-error(cs, "invalid unicode scalar value")

fun parse-literal-string( src : list<char>, cs : list<char>, acc : list<char> ) : exn (string, list<char>)
  match cs
    Cons('\'', rest) -> (acc.reverse.string, rest)
    Cons('\n', _) -> src.parse-error(cs, "newline in a string")
    Cons(c, rest) ->
      if c.is-toml-control then src.parse-error(cs, "control character in a string")
      else src.parse-literal-string(rest, Cons(c, acc))
    Nil -> src.parse-error(cs, "unterminated string")

fun parse-ml-basic( src : list<char>, cs : list<char>, acc : list<char> ) : exn (string, list<char>)
  match cs
    // up to two extra quotes may precede the closing delimiter
    Cons('"', Cons('"', Cons('"', Cons('"', Cons('"', rest))))) -> (Cons('"', Cons('"', acc)).reverse.string, rest)
    Cons('"', Cons('"', Cons('"', Cons('"', rest)))) -> (Cons('"', acc).reverse.string, rest)
    Cons('"', Cons('"', Cons('"', rest))) -> (acc.reverse.string, rest)
    Cons('\\', rest) ->
      // a backslash at the end of a line trims the newline and following whitespace
      val after = rest.skip-ws
      match after
        Cons('\n', _) -> src.parse-ml-basic(pretend-decreasing(src.trim-ws-nl(after)), acc)
        Cons('\r', Cons('\n', _)) -> src.parse-ml-basic(pretend-decreasing(src.trim-ws-nl(after)), acc)
        _ ->
          val (c, rest1) = src.parse-escape(rest)
          src.parse-ml-basic(pretend-decreasing(rest1), Cons(c, acc))
    Cons('\r', Cons('\n', rest)) -> src.parse-ml-basic(rest, Cons('\n', acc))
    Cons('\n', rest) -> src.parse-ml-basic(rest, Cons('\n', acc))
    Cons(c, rest) ->
      if c.is-toml-control then src.parse-error(cs, "control character in a string")
      else src.parse-ml-basic(rest, Cons(c, acc))
    Nil -> src.parse-error(cs, "unterminated multi-line string")

fun trim-ws-nl( src : list<char>, cs : list<char> ) : list<char>
  match cs
    Cons(c, rest) | c.is-ws || c == '\n' -> src.trim-ws-nl(rest)
    Cons('\r', Cons('\n', rest)) -> src.trim-ws-nl(rest)
    _ -> cs

fun parse-ml-literal( src : list<char>, cs : list<char>, acc : list<char> ) : exn (string, list<char>)
  match cs
    Cons('\'', Cons('\'', Cons('\'', Cons('\'', Cons('\'', rest))))) -> (Cons('\'', Cons('\'', acc)).reverse.string, rest)
    Cons('\'', Cons('\'', Cons('\'', Cons('\'', rest)))) -> (Cons('\'', acc).reverse.string, rest)
    Cons('\'', Cons('\'', Cons('\'', rest))) -> (acc.reverse.string, rest)
    Cons('\r', Cons('\n', rest)) -> src.parse-ml-literal(rest, Cons('\n', acc))
    Cons('\n', rest) -> src.parse-ml-literal(rest, Cons('\n', acc))
    Cons(c, rest) ->
      if c.is-toml-control then src.parse-error(cs, "control character in a string")
      else src.parse-ml-literal(rest, Cons(c, acc))
    Nil -> src.parse-error(cs, "unterminated multi-line string")

// ----------------------------------------------------------------------------
// Numbers, dates and times
// ----------------------------------------------------------------------------

fun digits-n( cs : list<char>, n : int ) : bool
  val ds = cs.take(n)
  ds.length == n && ds.all(is-digit)

fun parse-number-or-date( src : list<char>, cs : list<char> ) : exn (node, list<char>)
  if cs.digits-n(4) && cs.drop(4).head == Just('-') then src.parse-date(cs)
  elif cs.digits-n(2) && cs.drop(2).head == Just(':') then
    val (t, rest) = src.parse-time(cs)
    (NVal(TDatetime(Local-time, t.string)), rest)
  else src.parse-number(cs)

fun two-digits( src : list<char>, cs : list<char>, lo : int, hi : int, what : string ) : exn (list<char>, list<char>)
  if !cs.digits-n(2) then src.parse-error(cs, "expected two digits for the " ++ what)
  val ds = cs.take(2)
  val v = ds.string.parse-int.default(-1)
  if v < lo || v > hi then src.parse-error(cs, "invalid " ++ what)
  (ds, cs.drop(2))

fun parse-date( src : list<char>, cs : list<char> ) : exn (node, list<char>)
  val year = cs.take(4)
  val (month, r1) = src.two-digits(cs.drop(5), 1, 12, "month")
  match r1
    Cons('-', r2) ->
      val (day, r3) = src.two-digits(r2, 1, 31, "day")
      val y = year.string.parse-int.default(0)
      val m = month.string.parse-int.default(0)
      val leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
      val max-day = if m == 2 then (if leap then 29 else 28) elif m == 4 || m == 6 || m == 9 || m == 11 then 30 else 31
      if day.string.parse-int.default(0) > max-day then src.parse-error(r2, "invalid day")
      val date = year ++ ['-'] ++ month ++ ['-'] ++ day
      // a time may follow after `T`, `t` or a single space
      val time-start = match r3
        Cons(c, rest) | (c == 'T' || c == 't') -> Just(rest)
        Cons(' ', rest) | rest.digits-n(2) && rest.drop(2).head == Just(':') -> Just(rest)
        _ -> Nothing
      match time-start
        Nothing -> (NVal(TDatetime(Local-date, date.string)), r3)
        Just(ts) ->
          val (time, r4) = src.parse-time(ts)
          val (offset, r5) = src.parse-offset(r4)
          val text = (date ++ ['T'] ++ time ++ offset).string
          (NVal(TDatetime(if offset.is-empty then Local-datetime else Offset-datetime, text)), r5)
    _ -> src.parse-error(r1, "expected '-' in a date")

// `hh:mm:ss` with optional fractional seconds.
fun parse-time( src : list<char>, cs : list<char> ) : exn (list<char>, list<char>)
  val (h, r1) = src.two-digits(cs, 0, 23, "hour")
  match r1
    Cons(':', r2) ->
      val (m, r3) = src.two-digits(r2, 0, 59, "minute")
      match r3
        Cons(':', r4) ->
          val (s, r5) = src.two-digits(r4, 0, 60, "second")
          match r5
            Cons('.', r6) ->
              val frac = r6.take-while(is-digit)
              if frac.is-empty then src.parse-error(r6, "expected digits after '.'")
              (h ++ [':'] ++ m ++ [':'] ++ s ++ Cons('.', frac), r6.drop(frac.length))
            _ -> (h ++ [':'] ++ m ++ [':'] ++ s, r5)
        _ -> src.parse-error(r3, "expected ':' and seconds in a time")
    _ -> src.parse-error(r1, "expected ':' in a time")

fun parse-offset( src : list<char>, cs : list<char> ) : exn (list<char>, list<char>)
  match cs
    Cons(c, rest) | c == 'Z' || c == 'z' -> (['Z'], rest)
    Cons(c, rest) | c == '+' || c == '-' ->
      val (h, r1) = src.two-digits(rest, 0, 23, "offset hour")
      match r1
        Cons(':', r2) ->
          val (m, r3) = src.two-digits(r2, 0, 59, "offset minute")
          (Cons(c, h ++ [':'] ++ m), r3)
        _ -> src.parse-error(r1, "expected ':' in an offset")
    _ -> ([], cs)

// Digits with single underscores between them; returns the digits without underscores.
fun underscored( src : list<char>, cs : list<char>, ok : char -> bool ) : exn (list<char>, list<char>)
  val word = cs.take-while(fn(c) ok(c) || c == '_')
  if word.is-empty || word.head == Just('_') || word.last == Just('_') then src.parse-error(cs, "invalid number")
  if word.zip(word.drop(1)).any(fn((a, b)) a == '_' && b == '_') then src.parse-error(cs, "invalid number")
  (word.filter(fn(c) c != '_'), cs.drop(word.length))

fun parse-number( src : list<char>, cs : list<char> ) : exn (node, list<char>)
  val (sign, cs1) = match cs
    Cons(c, rest) | c == '+' || c == '-' -> ([c], rest)
    _ -> ([], cs)
  val neg = sign == ['-']
  match cs1
    Cons('i', Cons('n', Cons('f', rest))) -> (NVal(TFloat(if neg then neginf else posinf)), rest)
    Cons('n', Cons('a', Cons('n', rest))) -> (NVal(TFloat(nan)), rest)
    Cons('0', Cons(p, rest)) | p == 'x' || p == 'o' || p == 'b' ->
      if !sign.is-empty then src.parse-error(cs, "a sign is not allowed on hexadecimal, octal or binary numbers")
      val ok = match p
        'x' -> is-hex-digit
        'o' -> fn(c : char) c >= '0' && c <= '7'
        _   -> fn(c : char) c == '0' || c == '1'
      val (ds, rest1) = src.underscored(rest, ok)
      val base = match p { 'x' -> 16; 'o' -> 8; _ -> 2 }
      (NVal(TInt(ds.foldl(0, fn(acc, c) acc * base + c.hex-value))), rest1)
    _ ->
      val (int-part, rest1) = src.underscored(cs1, is-digit)
      if int-part.length > 1 && int-part.head == Just('0') then src.parse-error(cs1, "leading zeros are not allowed")
      val (frac, rest2) = match rest1
        Cons('.', r) ->
          val (ds, r') = src.underscored(r, is-digit)
          (Cons('.', ds), r')
        _ -> ([], rest1)
      val (expo, rest3) = match rest2
        Cons(e, r) | e == 'e' || e == 'E' ->
          val (esign, r1) = match r
            Cons(s, r0) | s == '+' || s == '-' -> ([s], r0)
            _ -> ([], r)
          val (ds, r2) = src.underscored(r1, is-digit)
          (Cons('e', esign ++ ds), r2)
        _ -> ([], rest2)
      match rest3
        Cons(c, _) | c.is-alpha-num || c == '.' || c == '_' -> src.parse-error(rest3, "invalid number")
        _ -> ()
      if frac.is-empty && expo.is-empty then
        val i = int-part.string.parse-int.default(0)
        (NVal(TInt(if neg then 0 - i else i)), rest3)
      else match parse-float64((sign ++ int-part ++ frac ++ expo).string)
        Just(f) -> (NVal(TFloat(f)), rest3)
        Nothing -> src.parse-error(cs, "invalid number")

fun hex-value( c : char ) : int
  if c >= '0' && c <= '9' then c.int - '0'.int
  elif c >= 'a' && c <= 'f' then c.int - 'a'.int + 10
  else c.int - 'A'.int + 10
