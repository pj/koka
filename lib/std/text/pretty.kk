/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* A pretty printer, in the style of Wadler's "A prettier printer" and
   Leijen's PPrint.

   A `:doc` describes text with optional line breaks. A `group` is laid out
   on one line if it fits in the page width, and otherwise its `line`s become
   newlines, indented by the enclosing `nest`s.

   ```
   import std/text/pretty

   fun call( f : string, args : list<doc> ) : doc
     text(f) ++ tupled(args)

   fun main()
     val d = call("frobnicate", [text("alpha"), text("beta"), call("inner", [text("gamma"), text("delta")])])
     println(d.pretty(80))   // frobnicate(alpha, beta, inner(gamma, delta))
     println(d.pretty(40))
     // frobnicate(alpha
     //           , beta
     //           , inner(gamma, delta))
   ```
*/
module std/text/pretty

import std/core/undiv

pub infixr 60 (++)
pub infixr 60 (<+>)
pub infixr 50 (<->)

// A document.
abstract type doc
  Empty
  Text( s : string )             // without newlines
  Line( flat : string )          // a newline, or `flat` when laid out on one line
  Hard-line                      // a newline that cannot be flattened
  Cat( a : doc, b : doc )
  Nest( i : int, d : doc )
  Group( d : doc )
  Column( f : int -> doc )       // the document depends on the current column
  Nesting( f : int -> doc )      // ... or the current indentation

// ----------------------------------------------------------------------------
// Basic documents
// ----------------------------------------------------------------------------

// The empty document.
pub val empty : doc = Empty

// Text; newlines in it become hard line breaks.
pub fun text( s : string ) : doc
  match s.split("\n")
    [single] -> if single.is-empty then Empty else Text(single)
    parts -> parts.map(fn(p) if p.is-empty then Empty else Text(p)).fold-docs(fn(a, b) Cat(a, Cat(Hard-line, b)))

fun fold-docs( xs : list<doc>, f : (doc, doc) -> doc ) : doc
  match xs
    Nil -> Empty
    Cons(x, Nil) -> x
    Cons(x, rest) -> f(x, rest.fold-docs(f))

pub fun string/doc( s : string ) : doc
  text(s)

pub fun int/doc( i : int ) : doc
  Text(i.show)

pub fun char/doc( c : char ) : doc
  text(c.string)

pub fun bool/doc( b : bool ) : doc
  Text(if b then "true" else "false")

// A line break, or a space when laid out on one line.
pub val line : doc = Line(" ")

// A line break, or nothing when laid out on one line.
pub val linebreak : doc = Line("")

// A space if the rest fits on the line, and otherwise a line break.
pub val softline : doc = Group(Line(" "))

// Nothing if the rest fits on the line, and otherwise a line break.
pub val softbreak : doc = Group(Line(""))

// A line break that is never laid out as a space (a group containing it is
// never flat).
pub val hardline : doc = Hard-line

pub val space : doc = Text(" ")

// `n` spaces.
pub fun spaces( n : int ) : doc
  if n <= 0 then Empty else Text(" ".repeat(n))

// ----------------------------------------------------------------------------
// Combining documents
// ----------------------------------------------------------------------------

// Concatenation.
pub fun (++)( a : doc, b : doc ) : doc
  match (a, b)
    (Empty, _) -> b
    (_, Empty) -> a
    _ -> Cat(a, b)

// Concatenation with a space in between (unless one is empty).
pub fun (<+>)( a : doc, b : doc ) : doc
  match (a, b)
    (Empty, _) -> b
    (_, Empty) -> a
    _ -> Cat(a, Cat(space, b))

// Concatenation with a `line` in between (unless one is empty).
pub fun (<->)( a : doc, b : doc ) : doc
  match (a, b)
    (Empty, _) -> b
    (_, Empty) -> a
    _ -> Cat(a, Cat(line, b))

// Lay out `d` on one line if it fits.
pub fun group( d : doc ) : doc
  Group(d)

// Indent the lines after the first (that is, after line breaks) by `i` more.
pub fun nest( d : doc, i : int ) : doc
  Nest(i, d)

// Indent line breaks in `d` to the column where `d` starts.
pub fun align( d : doc ) : doc
  Column(fn(k) Nesting(fn(i) Nest(k - i, d)))

// Indent line breaks in `d` to `i` past the column where `d` starts.
pub fun hang( d : doc, i : int ) : doc
  align(Nest(i, d))

// Indent all of `d` (including its first line) by `i`.
pub fun indent( d : doc, i : int ) : doc
  hang(spaces(i) ++ d, i)

// A document that depends on the current column.
pub fun column( f : int -> doc ) : doc
  Column(f)

// A document that depends on the current indentation.
pub fun nesting( f : int -> doc ) : doc
  Nesting(f)

// Pad `d` with spaces to `n` columns (if it is shorter).
pub fun fill( d : doc, n : int ) : doc
  Column fn(k)
    d ++ Column(fn(k2) spaces(n - (k2 - k)))

// Pad `d` with spaces to `n` columns, or start a new line (indented by `n`)
// after it if it is longer.
pub fun fill-break( d : doc, n : int ) : doc
  Column fn(k)
    d ++ Column(fn(k2) if k2 - k > n then Nest(n, linebreak) else spaces(n - (k2 - k)))

// Concatenate with `sep` between each two documents.
pub fun concat-with( ds : list<doc>, sep : (doc, doc) -> doc ) : doc
  ds.filter(fn(d) !d.is-empty-doc).fold-docs(sep)

fun is-empty-doc( d : doc ) : bool
  match d
    Empty -> True
    _ -> False

// Concatenate horizontally.
pub fun hcat( ds : list<doc> ) : doc
  ds.concat-with((++))

// Concatenate with spaces in between.
pub fun hsep( ds : list<doc> ) : doc
  ds.concat-with((<+>))

// Concatenate with `line`s in between.
pub fun vsep( ds : list<doc> ) : doc
  ds.concat-with((<->))

// Concatenate with `linebreak`s in between.
pub fun vcat( ds : list<doc> ) : doc
  ds.concat-with(fn(a, b) a ++ linebreak ++ b)

// All on one line separated by spaces if that fits, and otherwise one per line.
pub fun sep( ds : list<doc> ) : doc
  group(vsep(ds))

// All on one line if that fits, and otherwise one per line.
pub fun cat( ds : list<doc> ) : doc
  group(vcat(ds))

// As many as fit on each line, separated by spaces.
pub fun fill-sep( ds : list<doc> ) : doc
  ds.concat-with(fn(a, b) a ++ softline ++ b)

// As many as fit on each line.
pub fun fill-cat( ds : list<doc> ) : doc
  ds.concat-with(fn(a, b) a ++ softbreak ++ b)

// Append `p` to every document but the last.
pub fun punctuate( ds : list<doc>, p : doc ) : list<doc>
  match ds
    Nil -> Nil
    Cons(d, Nil) -> [d]
    Cons(d, rest) -> Cons(d ++ p, rest.punctuate(p))

pub fun enclose( d : doc, l : doc, r : doc ) : doc
  l ++ d ++ r

pub fun parens( d : doc ) : doc
  d.enclose(Text("("), Text(")"))

pub fun brackets( d : doc ) : doc
  d.enclose(Text("["), Text("]"))

pub fun braces( d : doc ) : doc
  d.enclose(Text("{"), Text("}"))

pub fun angles( d : doc ) : doc
  d.enclose(Text("<"), Text(">"))

pub fun dquotes( d : doc ) : doc
  d.enclose(Text("\""), Text("\""))

pub fun squotes( d : doc ) : doc
  d.enclose(Text("'"), Text("'"))

// The documents between `l` and `r`, separated by `sep`: on one line if it
// fits, and otherwise one per line with the separators in front, aligned
// with `l`.
pub fun enclose-sep( ds : list<doc>, l : doc, r : doc, sep : doc ) : doc
  match ds
    Nil -> l ++ r
    [d] -> l ++ d ++ r
    Cons(d, rest) ->
      val body = Cons(l ++ d, rest.map(fn(x) sep ++ x)).concat-with(fn(a, b) a ++ linebreak ++ b)
      align(group(body ++ r))

// A list `[a, b, c]`.
pub fun list-doc( ds : list<doc> ) : doc
  enclose-sep(ds, Text("["), Text("]"), Text(", "))

// A tuple `(a, b, c)`.
pub fun tupled( ds : list<doc> ) : doc
  enclose-sep(ds, Text("("), Text(")"), Text(", "))

// A block `{a; b; c}`.
pub fun semi-braces( ds : list<doc> ) : doc
  enclose-sep(ds, Text("{"), Text("}"), Text("; "))

// A block with its contents indented by `i` on separate lines (unless it
// fits on one line): `{ a; b }` or
// ```
// {
//   a
//   b
// }
// ```
pub fun block( ds : list<doc>, l : doc = Text("{"), r : doc = Text("}"), i : int = 2 ) : doc
  if ds.is-nil then l ++ r
  else group(l ++ Nest(i, line ++ vsep(ds)) ++ line ++ r)

// ----------------------------------------------------------------------------
// Rendering
// ----------------------------------------------------------------------------

// Lay out a document for a page `width` columns wide.
pub fun pretty( d : doc, width : int = 80 ) : string
  pretend-no-div { render(width, 0, [(0, False, d)], []) }.reverse.join

pub fun show( d : doc ) : string
  d.pretty

// The items are `(indentation, flat, document)`; the output is in reverse.
fun render( width : int, k : int, items : list<(int, bool, doc)>, out : list<string> ) : div list<string>
  match items
    Nil -> out
    Cons((i, flat, d), rest) -> match d
      Empty -> render(width, k, rest, out)
      Text(s) -> render(width, k + s.count, rest, Cons(s, out))
      Line(f) ->
        if flat then render(width, k + f.count, rest, Cons(f, out))
        else render(width, i, rest, Cons(newline(i), out))
      Hard-line -> render(width, i, rest, Cons(newline(i), out))
      Cat(a, b) -> render(width, k, Cons((i, flat, a), Cons((i, flat, b), rest)), out)
      Nest(j, x) -> render(width, k, Cons((i + j, flat, x), rest), out)
      Group(x) ->
        if flat then render(width, k, Cons((i, True, x), rest), out)
        else
          val fl = fits(width - k, k, Cons((i, True, x), rest))
          render(width, k, Cons((i, fl, x), rest), out)
      Column(f) -> render(width, k, Cons((i, flat, f(k)), rest), out)
      Nesting(f) -> render(width, k, Cons((i, flat, f(i)), rest), out)

fun newline( i : int ) : string
  "\n" ++ " ".repeat(i)

// Does the text up to the next line break (in a non-flat item) fit in `w` columns?
fun fits( w : int, k : int, items : list<(int, bool, doc)> ) : div bool
  if w < 0 then False
  else match items
    Nil -> True
    Cons((i, flat, d), rest) -> match d
      Empty -> fits(w, k, rest)
      Text(s) -> fits(w - s.count, k + s.count, rest)
      Line(f) -> if flat then fits(w - f.count, k + f.count, rest) else True
      Hard-line -> !flat
      Cat(a, b) -> fits(w, k, Cons((i, flat, a), Cons((i, flat, b), rest)))
      Nest(j, x) -> fits(w, k, Cons((i + j, flat, x), rest))
      Group(x) -> fits(w, k, Cons((i, flat, x), rest))
      Column(f) -> fits(w, k, Cons((i, flat, f(k)), rest))
      Nesting(f) -> fits(w, k, Cons((i, flat, f(i)), rest))
