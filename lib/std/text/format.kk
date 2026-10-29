/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* String formatting with placeholders.

   `format(fmt, args)` replaces placeholders in `fmt` by the (already shown)
   arguments:

   - `{}` the next argument, `{0}`, `{1}`, ... a specific argument,
   - an optional format spec after a colon: `{:[[fill]align][width]}` where
     `align` is `<` (left), `>` (right), or `^` (center), and `fill` is any
     character (default a space), for example `{:>8}`, `{1:*^10}`, `{:08}`,
   - `{{` and `}}` for literal braces.

   ```
   format("{} is {} years old", ["ann", 30.show])   // "ann is 30 years old"
   format("[{:>6}] [{:<6}] [{:^6}]", ["a","b","c"])  // "[     a] [b     ] [  c   ]"
   format("{:08}", [42.show])                         // "00000042"
   ```
*/
module std/text/format

import std/core/undiv

// Format a string with placeholders (see the module documentation).
// Raises an exception for malformed placeholders or missing arguments.
pub fun format( fmt : string, args : list<string> ) : exn string
  val argv = args.vector
  fmt-chars(fmt.list, argv, 0, []).reverse.string

fun fmt-chars( cs : list<char>, args : vector<string>, next : int, acc : list<char> ) : exn list<char>
  match cs
    Nil -> acc
    Cons('{', Cons('{', rest)) -> fmt-chars(rest, args, next, Cons('{', acc))
    Cons('}', Cons('}', rest)) -> fmt-chars(rest, args, next, Cons('}', acc))
    Cons('}', _) -> throw("format: single '}' in format string")
    Cons('{', rest) ->
      val spec = rest.take-while(fn(c) c != '}')
      if spec.length == rest.length then throw("format: unterminated '{' in format string")
      val rest' = rest.drop(spec.length + 1)
      val (index-part, fmt-part) = match spec.split-at-colon
        Just((i, f)) -> (i, f)
        Nothing -> (spec, [])
      val (index, next') = if index-part.is-empty then (next, next + 1)
                           else match parse-int(index-part.string)
                             Just(i) -> (i, next)
                             Nothing -> throw("format: invalid argument index " ++ index-part.string.show)
      val arg = match args.at(index)
        Just(a) -> a
        Nothing -> throw("format: missing argument " ++ index.show)
      val formatted = apply-spec(arg, fmt-part)
      fmt-chars(pretend-decreasing(rest'), args, next', formatted.list.reverse ++ acc)
    Cons(c, rest) -> fmt-chars(rest, args, next, Cons(c, acc))

fun split-at-colon( cs : list<char> ) : maybe<(list<char>, list<char>)>
  match cs.span(fn(c) c != ':')
    (before, Cons(':', after)) -> Just((before, after))
    _ -> Nothing

fun is-align( c : char ) : bool
  c == '<' || c == '>' || c == '^'

// Apply `[[fill]align][width]` to a string.
fun apply-spec( s : string, spec : list<char> ) : exn string
  if spec.is-empty then return s
  val (fill, align, width-part) = match spec
    Cons(f, Cons(a, rest)) | a.is-align -> (f, a, rest)
    Cons(a, rest) | a.is-align -> (' ', a, rest)
    Cons('0', rest) -> ('0', '>', rest)
    _ -> (' ', '<', spec)
  val width = if width-part.is-empty then 0
              else match parse-int(width-part.string)
                Just(w) -> w
                Nothing -> throw("format: invalid format spec " ++ spec.string.show)
  pad(s, width, fill, align)

// Pad a string to `width` characters with `fill`, aligned left (`<`), right (`>`) or centered (`^`).
pub fun pad( s : string, width : int, fill : char = ' ', align : char = '<' ) : string
  val n = s.count
  if n >= width then s
  else
    val total = width - n
    match align
      '>' -> fill.string.repeat(total) ++ s
      '^' ->
        val left = total / 2
        fill.string.repeat(left) ++ s ++ fill.string.repeat(total - left)
      _ -> s ++ fill.string.repeat(total)
