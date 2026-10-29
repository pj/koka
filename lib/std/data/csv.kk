/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Comma separated values (RFC 4180).

   ```
   val rows = parse-csv("name,age\nann,30\n\"bob, jr\",25\n")
   // [["name","age"],["ann","30"],["bob, jr","25"]]
   rows.to-csv   // back to text, quoting fields where needed
   ```

   Fields may be quoted with `"`; a quote inside a quoted field is written as
   `""`. Both `\n` and `\r\n` line endings are accepted.
*/
module std/data/csv

import std/core/undiv

// Parse CSV text into rows of fields. Raises an exception on an unterminated quoted field.
pub fun parse-csv( s : string, sep : char = ',' ) : exn list<list<string>>
  csv-rows(s.list, sep, [], [], [])

// Parse CSV text with a header row into records of `(column-name, value)` pairs.
pub fun parse-csv-records( s : string, sep : char = ',' ) : exn list<list<(string, string)>>
  match parse-csv(s, sep)
    Cons(header, rows) -> rows.map(fn(row) zip(header, row))
    Nil -> []

// cs: remaining input, field: current field (reversed), row: fields so far (reversed), rows: rows so far (reversed)
fun csv-rows( cs : list<char>, sep : char, field : list<char>, row : list<string>, rows : list<list<string>> ) : exn list<list<string>>
  match cs
    Nil ->
      if field.is-empty && row.is-empty then rows.reverse
      else Cons(Cons(field.reverse.string, row).reverse, rows).reverse
    Cons('"', rest) | field.is-empty ->
      val (quoted, rest') = csv-quoted(rest, [])
      csv-rows(pretend-decreasing(rest'), sep, quoted.reverse, row, rows)
    Cons('\r', Cons('\n', rest)) -> csv-rows(rest, sep, [], [], Cons(Cons(field.reverse.string, row).reverse, rows))
    Cons('\n', rest) -> csv-rows(rest, sep, [], [], Cons(Cons(field.reverse.string, row).reverse, rows))
    Cons(c, rest) ->
      if c == sep then csv-rows(rest, sep, [], Cons(field.reverse.string, row), rows)
      else csv-rows(rest, sep, Cons(c, field), row, rows)

// parse a quoted field (after the opening quote); returns the contents and the rest
fun csv-quoted( cs : list<char>, acc : list<char> ) : exn (list<char>, list<char>)
  match cs
    Cons('"', Cons('"', rest)) -> csv-quoted(rest, Cons('"', acc))
    Cons('"', rest) -> (acc.reverse, rest)
    Cons(c, rest) -> csv-quoted(rest, Cons(c, acc))
    Nil -> throw("csv: unterminated quoted field")

// Quote a field if it contains the separator, a quote, or a line break.
pub fun quote-field( field : string, sep : char = ',' ) : string
  if field.list.any(fn(c) c == sep || c == '"' || c == '\n' || c == '\r') then
    "\"" ++ field.replace-all("\"", "\"\"") ++ "\""
  else field

// Convert rows of fields to CSV text (each row is terminated by `\n`).
pub fun to-csv( rows : list<list<string>>, sep : char = ',' ) : string
  rows.map(fn(row) row.map(fn(f) f.quote-field(sep)).join(sep.string) ++ "\n").join
