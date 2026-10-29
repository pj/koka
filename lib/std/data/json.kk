/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* JSON values, parsing, and serialization (RFC 8259).

   ```
   import std/data/json

   fun main()
     val j = parse-json(r#"{"name": "koka", "tags": ["fun", "effects"], "version": 3}"#)
     println(j.at("name").as-string)                    // Just("koka")
     println(j.at("tags").as-array.map(fn(xs) xs.length)) // Just(2)
     val out = json-object([("ok", True.json), ("n", 42.json), ("xs", [1,2,3].json)])
     println(out.stringify)                             // {"ok":true,"n":42,"xs":[1,2,3]}
     println(out.pretty)
   ```

   Numbers without a fraction or exponent are parsed as `JInt` (with arbitrary
   precision); other numbers as `JFloat`. Objects keep the order of their keys.

   To convert your own types, define a `json` function for them (taking the
   value and returning a `:json`); it is then used automatically for lists,
   maybes, tuples etc. through the implicit `?json` parameter.
*/
module std/data/json

import std/core/undiv
import std/num/float64
import std/text/builder

// A JSON value.
pub type json
  JNull
  JBool( b : bool )
  JInt( i : int )
  JFloat( f : float64 )
  JString( s : string )
  JArray( items : list<json> )
  JObject( fields : list<(string, json)> )

// ----------------------------------------------------------------------------
// Construction
// ----------------------------------------------------------------------------

pub fun bool/json( b : bool ) : json
  JBool(b)

pub fun int/json( i : int ) : json
  JInt(i)

pub fun float64/json( f : float64 ) : json
  JFloat(f)

pub fun string/json( s : string ) : json
  JString(s)

pub fun char/json( c : char ) : json
  JString(c.string)

pub fun unit/json( _u : () ) : json
  JNull

pub fun json/json( j : json ) : json
  j

pub fun list/json( xs : list<a>, ?json : a -> e json ) : e json
  JArray(xs.map(fn(x) json(x)))

pub fun vector/json( xs : vector<a>, ?json : a -> e json ) : e json
  JArray(xs.list.map(fn(x) json(x)))

// `Nothing` becomes `null`.
pub fun maybe/json( m : maybe<a>, ?json : a -> e json ) : e json
  match m
    Just(x) -> json(x)
    Nothing -> JNull

// A pair becomes a two-element array.
pub fun tuple2/json( (a,b) : (a,b), ?fst/json : a -> e json, ?snd/json : b -> e json ) : e json
  JArray([fst/json(a), snd/json(b)])

// Create an object from a list of fields.
pub fun json-object( fields : list<(string, json)> ) : json
  JObject(fields)

// Create an array from a list of values.
pub fun json-array( items : list<json> ) : json
  JArray(items)

// ----------------------------------------------------------------------------
// Access
// ----------------------------------------------------------------------------

// The value of field `key` in an object (or `JNull` if absent or not an object).
pub fun at( j : json, key : string ) : json
  match j
    JObject(fields) -> fields.lookup(fn(k) k == key).default(JNull)
    _ -> JNull

// The value of field `key` in an object.
pub fun field( j : json, key : string ) : maybe<json>
  match j
    JObject(fields) -> fields.lookup(fn(k) k == key)
    _ -> Nothing

// Index a json value: `j["name"]` raises an exception if the field is absent.
pub fun @index( j : json, key : string ) : exn json
  match j.field(key)
    Just(v) -> v
    Nothing -> throw("std/data/json: field " ++ key.show ++ " not found")

// The element at position `i` of an array (or `JNull`).
pub fun index( j : json, i : int ) : json
  match j
    JArray(items) -> items.drop(i).head.default(JNull)
    _ -> JNull

// Follow a path of object keys, for example `j.path(["user","name"])`.
pub fun path( j : json, keys : list<string> ) : json
  keys.foldl(j, fn(acc, k) acc.at(k))

pub fun is-null( j : json ) : bool
  match j
    JNull -> True
    _ -> False

pub fun as-bool( j : json ) : maybe<bool>
  match j
    JBool(b) -> Just(b)
    _ -> Nothing

pub fun as-int( j : json ) : maybe<int>
  match j
    JInt(i) -> Just(i)
    JFloat(f) -> if f == f.truncate && f.is-finite then Just(f.int) else Nothing
    _ -> Nothing

// Integers are also converted to `:float64`.
pub fun as-float( j : json ) : maybe<float64>
  match j
    JFloat(f) -> Just(f)
    JInt(i) -> Just(i.float64)
    _ -> Nothing

pub fun as-string( j : json ) : maybe<string>
  match j
    JString(s) -> Just(s)
    _ -> Nothing

pub fun as-array( j : json ) : maybe<list<json>>
  match j
    JArray(xs) -> Just(xs)
    _ -> Nothing

pub fun as-object( j : json ) : maybe<list<(string, json)>>
  match j
    JObject(fs) -> Just(fs)
    _ -> Nothing

// The keys of an object (or `[]`).
pub fun keys( j : json ) : list<string>
  match j
    JObject(fs) -> fs.map(fn((k,_)) k)
    _ -> []

// Set (or add) field `key` of an object; non-objects are turned into an object.
pub fun set( j : json, key : string, value : json ) : json
  match j
    JObject(fs) ->
      if fs.any(fn((k,_)) k == key) then JObject(fs.map(fn((k,v)) if k == key then (k,value) else (k,v)))
      else JObject(fs ++ [(key, value)])
    _ -> JObject([(key, value)])

// Remove field `key` from an object.
pub fun remove( j : json, key : string ) : json
  match j
    JObject(fs) -> JObject(fs.filter(fn((k,_)) k != key))
    _ -> j

// Structural equality; objects are equal if they have the same fields
// (in any order), and `1` equals `1.0`.
pub fun (==)( j1 : json, j2 : json ) : bool
  match (j1, j2)
    (JNull, JNull) -> True
    (JBool(a), JBool(b)) -> a == b
    (JInt(a), JInt(b)) -> a == b
    (JString(a), JString(b)) -> a == b
    (JArray(xs), JArray(ys)) -> xs.length == ys.length && zipwith(xs, ys, fn(x,y) pretend-decreasing(x) == y).all(id)
    (JObject(xs), JObject(ys)) ->
      xs.length == ys.length && xs.all fn((k,v))
        match ys.lookup(fn(k2) k2 == k)
          Just(w) -> pretend-decreasing(v) == w
          Nothing -> False
    _ -> match (j1.as-float, j2.as-float)
      (Just(a), Just(b)) -> a == b
      _ -> False

pub fun (!=)( j1 : json, j2 : json ) : bool
  !(j1 == j2)

// ----------------------------------------------------------------------------
// Serialization
// ----------------------------------------------------------------------------

// Escape a string as a JSON string literal (including the quotes).
pub fun quote( s : string ) : string
  var acc := ['"']
  s.foreach fn(c)
    acc := quote-char(c, acc)
  Cons('"', acc).reverse.string

// prepend the escaped character `c` (in reverse) to `acc`
fun quote-char( c : char, acc : list<char> ) : list<char>
  match c
    '"'  -> Cons('"', Cons('\\', acc))
    '\\' -> Cons('\\', Cons('\\', acc))
    '\n' -> Cons('n', Cons('\\', acc))
    '\r' -> Cons('r', Cons('\\', acc))
    '\t' -> Cons('t', Cons('\\', acc))
    _ -> if c.int < 0x20 then ("\\u" ++ c.int.show-hex(4, pre="")).list.reverse ++ acc
         else Cons(c, acc)

fun show-number( f : float64 ) : string
  if f.is-nan || f.is-inf then "null"
  elif f == f.truncate && f.abs < 1.0e15 then f.int.show ++ ".0"
  else shortest-show(f, 1)

// the shortest representation that parses back to exactly the same number
fun shortest-show( f : float64, prec : int ) : string
  val s = f.show(0 - prec)
  if prec >= 17 || parse-float64(s) == Just(f) then s
  else shortest-show(f, pretend-decreasing(prec + 1))

// Serialize to compact JSON text.
pub fun stringify( j : json ) : string
  build { emit-json(j, -1, 0) }

// Serialize to JSON text with newlines and `indent` spaces of indentation.
pub fun pretty( j : json, indent : int = 2 ) : string
  build { emit-json(j, indent, 0) }

pub fun show( j : json ) : string
  j.stringify

fun emit-json( j : json, indent : int, level : int ) : emit ()
  match j
    JNull -> emit("null")
    JBool(b) -> emit(if b then "true" else "false")
    JInt(i) -> emit(i.show)
    JFloat(f) -> emit(f.show-number)
    JString(s) -> emit(s.quote)
    JArray(Nil) -> emit("[]")
    JObject(Nil) -> emit("{}")
    JArray(xs) ->
      emit("[")
      xs.foreach-indexed fn(i, x)
        if i > 0 then emit(",")
        emit-newline(indent, level + 1)
        emit-json(pretend-decreasing(x), indent, level + 1)
      emit-newline(indent, level)
      emit("]")
    JObject(fs) ->
      emit("{")
      fs.foreach-indexed fn(i, (k, v))
        if i > 0 then emit(",")
        emit-newline(indent, level + 1)
        emit(k.quote)
        emit(if indent >= 0 then ": " else ":")
        emit-json(pretend-decreasing(v), indent, level + 1)
      emit-newline(indent, level)
      emit("}")

fun emit-newline( indent : int, level : int ) : emit ()
  if indent >= 0 then
    emit("\n")
    emit(" ".repeat(indent * level))

// ----------------------------------------------------------------------------
// Parsing
// ----------------------------------------------------------------------------

// Parse JSON text. Raises an exception with the line and column on a syntax error.
pub fun parse-json( s : string ) : exn json
  val cs = s.list
  val (v, rest) = pretend-no-div { cs.parse-value(cs) }
  val rest' = rest.skip-ws
  match rest'
    Nil -> v
    _ -> cs.parse-error(rest', "unexpected trailing characters")

// Parse JSON text, returning `Nothing` on a syntax error.
pub fun try-parse-json( s : string ) : maybe<json>
  catch(fn(_) Nothing, { Just(parse-json(s)) })

fun parse-error( src : list<char>, rest : list<char>, msg : string ) : exn a
  val consumed = src.take(src.length - rest.length)
  val line = consumed.filter(fn(c) c == '\n').length + 1
  val col = consumed.reverse.take-while(fn(c) c != '\n').length + 1
  throw("json parse error at line " ++ line.show ++ ", column " ++ col.show ++ ": " ++ msg)

fun skip-ws( cs : list<char> ) : list<char>
  match cs
    Cons(c, cc) | c == ' ' || c == '\n' || c == '\r' || c == '\t' -> skip-ws(cc)
    _ -> cs

fun expect-word( src : list<char>, cs : list<char>, word : string, v : json ) : exn (json, list<char>)
  val n = word.count
  if cs.take(n).string == word then (v, cs.drop(n))
  else src.parse-error(cs, "invalid literal")

fun parse-value( src : list<char>, input : list<char> ) : <div,exn> (json, list<char>)
  val cs = input.skip-ws
  match cs
    Cons('{', rest) -> src.parse-object(rest.skip-ws, [])
    Cons('[', rest) -> src.parse-array(rest.skip-ws, [])
    Cons('"', rest) ->
      val (s, rest') = src.parse-string(rest, [])
      (JString(s), rest')
    Cons('t', _) -> src.expect-word(cs, "true", JBool(True))
    Cons('f', _) -> src.expect-word(cs, "false", JBool(False))
    Cons('n', _) -> src.expect-word(cs, "null", JNull)
    Cons(c, _) | c == '-' || c.is-digit -> src.parse-number(cs)
    Nil -> src.parse-error(cs, "unexpected end of input")
    _ -> src.parse-error(cs, "unexpected character")

fun parse-array( src : list<char>, cs : list<char>, acc : list<json> ) : <div,exn> (json, list<char>)
  match cs
    Cons(']', rest) | acc.is-empty -> (JArray([]), rest)
    _ ->
      val (v, rest) = src.parse-value(cs)
      match rest.skip-ws
        Cons(',', rest') -> src.parse-array(pretend-decreasing(rest'), Cons(v, acc))
        Cons(']', rest') -> (JArray(Cons(v, acc).reverse), rest')
        rest' -> src.parse-error(rest', "expected ',' or ']'")

fun parse-object( src : list<char>, cs : list<char>, acc : list<(string,json)> ) : <div,exn> (json, list<char>)
  match cs
    Cons('}', rest) | acc.is-empty -> (JObject([]), rest)
    Cons('"', rest) ->
      val (key, rest1) = src.parse-string(rest, [])
      match rest1.skip-ws
        Cons(':', rest2) ->
          val (v, rest3) = src.parse-value(rest2)
          match rest3.skip-ws
            Cons(',', rest4) -> src.parse-object(pretend-decreasing(rest4.skip-ws), Cons((key, v), acc))
            Cons('}', rest4) -> (JObject(Cons((key, v), acc).reverse), rest4)
            rest4 -> src.parse-error(rest4, "expected ',' or '}'")
        rest2 -> src.parse-error(rest2, "expected ':'")
    _ -> src.parse-error(cs, "expected a string key")

fun hex4( src : list<char>, cs : list<char> ) : exn (int, list<char>)
  val ds = cs.take(4)
  if ds.length == 4 && ds.all(is-hex-digit) then
    match parse-int(ds.string, hex=True)
      Just(i) -> (i, cs.drop(4))
      Nothing -> src.parse-error(cs, "invalid unicode escape")
  else src.parse-error(cs, "invalid unicode escape")

fun parse-string( src : list<char>, cs : list<char>, acc : list<char> ) : exn (string, list<char>)
  match cs
    Cons('"', rest) -> (acc.reverse.string, rest)
    Cons('\\', Cons(e, rest)) ->
      match e
        '"' -> src.parse-string(rest, Cons('"', acc))
        '\\' -> src.parse-string(rest, Cons('\\', acc))
        '/' -> src.parse-string(rest, Cons('/', acc))
        'b' -> src.parse-string(rest, Cons(8.char, acc))
        'f' -> src.parse-string(rest, Cons(12.char, acc))
        'n' -> src.parse-string(rest, Cons('\n', acc))
        'r' -> src.parse-string(rest, Cons('\r', acc))
        't' -> src.parse-string(rest, Cons('\t', acc))
        'u' ->
          val (hi, rest1) = src.hex4(rest)
          if hi >= 0xD800 && hi <= 0xDBFF then
            match rest1
              Cons('\\', Cons('u', rest2)) ->
                val (lo, rest3) = src.hex4(rest2)
                if lo >= 0xDC00 && lo <= 0xDFFF then
                  src.parse-string(pretend-decreasing(rest3), Cons((0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)).char, acc))
                else src.parse-error(rest2, "invalid surrogate pair")
              _ -> src.parse-error(rest1, "unpaired surrogate")
          else src.parse-string(pretend-decreasing(rest1), Cons(hi.char, acc))
        _ -> src.parse-error(cs, "invalid escape")
    Cons(c, rest) ->
      if c.int < 0x20 then src.parse-error(cs, "control character in string")
      else src.parse-string(rest, Cons(c, acc))
    Nil -> src.parse-error(cs, "unterminated string")

fun parse-number( src : list<char>, cs : list<char> ) : exn (json, list<char>)
  val (sign, cs1) = match cs
    Cons('-', rest) -> ("-", rest)
    _ -> ("", cs)
  val int-digits = cs1.take-while(is-digit)
  if int-digits.is-empty then src.parse-error(cs1, "expected a digit")
  if int-digits.length > 1 && int-digits.head == Just('0') then src.parse-error(cs1, "leading zero")
  val cs2 = cs1.drop(int-digits.length)
  val (frac, cs3) = match cs2
    Cons('.', rest) ->
      val ds = rest.take-while(is-digit)
      if ds.is-empty then src.parse-error(rest, "expected a digit after '.'")
      (Cons('.', ds), rest.drop(ds.length))
    _ -> ([], cs2)
  val (expo, cs4) = match cs3
    Cons(e, rest) | e == 'e' || e == 'E' ->
      val (esign, rest1) = match rest
        Cons(s, r) | s == '+' || s == '-' -> ([s], r)
        _ -> ([], rest)
      val ds = rest1.take-while(is-digit)
      if ds.is-empty then src.parse-error(rest1, "expected a digit in exponent")
      (Cons('e', esign ++ ds), rest1.drop(ds.length))
    _ -> ([], cs3)
  if frac.is-empty && expo.is-empty then
    match parse-int(sign ++ int-digits.string)
      Just(i) -> (JInt(i), cs4)
      Nothing -> src.parse-error(cs, "invalid number")
  else
    match parse-float64(sign ++ int-digits.string ++ frac.string ++ expo.string)
      Just(f) -> (JFloat(f), cs4)
      Nothing -> src.parse-error(cs, "invalid number")
