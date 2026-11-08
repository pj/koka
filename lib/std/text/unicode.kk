/*---------------------------------------------------------------------------
  Copyright 2012-2026, Microsoft Research, Daan Leijen, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Unicode text: graphemes, words, display width, case folding and
   normalization.

   ```
   import std/text/unicode

   fun main()
     println("é👍🏽🇳🇿".graphemes)                 // ["é","👍🏽","🇳🇿"]
     println("Hello, world! 3.14".words)                 // ["Hello","world","3.14"]
     println("日本 ok 👍".width)                          // 10
     println("Straße".fold-case == "STRASSE".fold-case)  // True
     println("é".normalize(NFC).count)              // 1
   ```

   Graphemes and words follow the Unicode text segmentation rules (UAX #29,
   extended grapheme clusters and default word boundaries), and the tables
   are generated from the Unicode Character Database (see
   `unicode-version`), so the results are the same on every backend.
*/
module std/text/unicode

import std/core/undiv
import std/core/delayed
pub import std/text/unicode-tables

// A grapheme: a user-perceived character, such as a letter with its accents,
// a flag, or an emoji with its modifiers, as a `:string`.
pub alias grapheme = string

// ----------------------------------------------------------------------------
// Property tables
// ----------------------------------------------------------------------------

// A decoded table of ranges `lo..lo+len` with a value.
struct ranges( los : vector<int>, lens : vector<int>, vals : vector<int> )

fun hex-digit( c : char ) : int
  if c >= '0' && c <= '9' then c.int - '0'.int
  elif c >= 'a' && c <= 'f' then c.int - 'a'.int + 10
  else c.int - 'A'.int + 10

// Decode `lo.len.value,...` (hex, newlines ignored).
fun decode-ranges( s : string ) : ranges
  var los := []
  var lens := []
  var vals := []
  var fields := []
  var cur := 0
  s.foreach fn(c)
    if c == '.' then
      fields := Cons(cur, fields)
      cur := 0
    elif c == ',' then
      match fields
        [len, lo] -> { los := Cons(lo, los); lens := Cons(len, lens); vals := Cons(cur, vals) }
        _ -> ()
      fields := []
      cur := 0
    elif c != '\n' then cur := cur * 16 + c.hex-digit
  match fields
    [len, lo] -> { los := Cons(lo, los); lens := Cons(len, lens); vals := Cons(cur, vals) }
    _ -> ()
  Ranges(los.reverse.vector, lens.reverse.vector, vals.reverse.vector)

fun at0( v : vector<int>, i : int ) : int
  v.at(i).default(0)

// The value for `cp`, or 0.
fun lookup( r : ranges, cp : int ) : int
  fun go( lo : int, hi : int ) : int
    if lo >= hi then 0
    else
      val mid = (lo + hi) / 2
      val start = r.los.at0(mid)
      if cp < start then go(lo, pretend-decreasing(mid))
      elif cp > start + r.lens.at0(mid) then go(pretend-decreasing(mid + 1), hi)
      else r.vals.at0(mid)
  go(0, r.los.length)

val grapheme-table : delayed<total,ranges> = delay { decode-ranges(grapheme-props) }
val word-table : delayed<total,ranges> = delay { decode-ranges(word-props) }
val width-table : delayed<total,ranges> = delay { decode-ranges(width-props) }
val ccc-table : delayed<total,ranges> = delay { decode-ranges(ccc-props) }

// ----------------------------------------------------------------------------
// Graphemes (UAX #29 extended grapheme clusters)
// ----------------------------------------------------------------------------

// Grapheme_Cluster_Break values (as in the generated table)
val gOther = 0
val gCR = 1
val gLF = 2
val gControl = 3
val gExtend = 4
val gZWJ = 5
val gRI = 6
val gPrepend = 7
val gSpacingMark = 8
val gL = 9
val gV = 10
val gT = 11
val gLV = 12
val gLVT = 13

// InCB values
val incbLinker = 1
val incbConsonant = 2
val incbExtend = 3

fun gprops( c : char ) : int
  grapheme-table.force.lookup(c.int)

// Is this a combining character (a mark that extends the grapheme before it)?
pub fun is-combining( c : char ) : bool
  val p = c.gprops % 16
  p == gExtend || p == gSpacingMark

// The state between two characters while segmenting graphemes.
value struct gstate
  prev : int        // the break property of the previous character
  ri-odd : bool     // an odd number of regional indicators precede
  emoji : bool      // the text so far ends with Extended_Pictographic Extend*
  emoji-zwj : bool  // ... followed by a ZWJ
  consonant : bool  // the text so far ends with InCB=Consonant [Extend Linker]*
  linked : bool     // ... with a Linker in that tail

val gstart : gstate = Gstate(-1, False, False, False, False, False)

// Is there a grapheme boundary before a character with properties `p`?
fun grapheme-break( st : gstate, p : int ) : bool
  val a = st.prev
  val b = p % 16
  val incb = (p / 32) % 4
  if a < 0 then True                                                             // GB1
  elif a == gCR && b == gLF then False                                           // GB3
  elif a == gControl || a == gCR || a == gLF then True                           // GB4
  elif b == gControl || b == gCR || b == gLF then True                           // GB5
  elif a == gL && (b == gL || b == gV || b == gLV || b == gLVT) then False        // GB6
  elif (a == gLV || a == gV) && (b == gV || b == gT) then False                  // GB7
  elif (a == gLVT || a == gT) && b == gT then False                              // GB8
  elif b == gExtend || b == gZWJ then False                                      // GB9
  elif b == gSpacingMark then False                                              // GB9a
  elif a == gPrepend then False                                                  // GB9b
  elif incb == incbConsonant && st.linked then False                             // GB9c
  elif a == gZWJ && (p / 16) % 2 == 1 && st.emoji-zwj then False                 // GB11
  elif a == gRI && b == gRI && st.ri-odd then False                              // GB12, GB13
  else True                                                                      // GB999

fun gstep( st : gstate, p : int ) : gstate
  val b = p % 16
  val pict = (p / 16) % 2 == 1
  val incb = (p / 32) % 4
  val in-emoji = pict || (st.emoji && b == gExtend)
  val (consonant, linked) =
    if incb == incbConsonant then (True, False)
    elif st.consonant && (incb == incbExtend || incb == incbLinker) then (True, st.linked || incb == incbLinker)
    else (False, False)
  Gstate(b, b == gRI && !st.ri-odd, in-emoji, b == gZWJ && st.emoji, consonant, linked)

// Split a string into graphemes. Concatenating them gives back the string.
pub fun graphemes( s : string ) : list<grapheme>
  segments(s.list, gstart, [], [])

fun segments( cs : list<char>, st : gstate, cur : list<char>, acc : list<grapheme> ) : list<grapheme>
  match cs
    Nil -> (if cur.is-nil then acc else Cons(cur.reverse.string, acc)).reverse
    Cons(c, rest) ->
      val p = c.gprops
      if grapheme-break(st, p) && !cur.is-nil then segments(rest, gstep(st, p), [c], Cons(cur.reverse.string, acc))
      else segments(rest, gstep(st, p), Cons(c, cur), acc)

// The number of graphemes.
pub fun grapheme-count( s : string ) : int
  s.graphemes.length

// ----------------------------------------------------------------------------
// Words (UAX #29 default word boundaries)
// ----------------------------------------------------------------------------

val wCR = 1
val wLF = 2
val wNewline = 3
val wExtend = 4
val wZWJ = 5
val wRI = 6
val wFormat = 7
val wKatakana = 8
val wHebrew = 9
val wALetter = 10
val wSingleQuote = 11
val wDoubleQuote = 12
val wMidNumLet = 13
val wMidLetter = 14
val wMidNum = 15
val wNumeric = 16
val wExtendNumLet = 17
val wWSegSpace = 18

fun is-ignorable( w : int ) : bool
  w == wExtend || w == wFormat || w == wZWJ

fun is-ahletter( w : int ) : bool
  w == wALetter || w == wHebrew

fun is-midnumletq( w : int ) : bool
  w == wMidNumLet || w == wSingleQuote

// The word break properties of a string's characters.
struct wtext( chars : vector<char>, props : vector<int> )

fun wtext/length( t : wtext ) : int
  t.chars.length

// The Word_Break value at `i` (-1 outside the text).
fun wb( t : wtext, i : int ) : int
  if i < 0 || i >= t.length then -1 else t.props.at0(i) % 32

fun is-pict( t : wtext, i : int ) : bool
  (t.props.at0(i) / 32) % 2 == 1

// The last character at or before `i` that is not Extend/Format/ZWJ (WB4).
fun prev-real( t : wtext, i : int ) : int
  if i < 0 then -1 elif t.wb(i).is-ignorable then t.prev-real(pretend-decreasing(i - 1)) else i

// The first character at or after `i` that is not Extend/Format/ZWJ.
fun next-real( t : wtext, i : int ) : int
  if i >= t.length then t.length elif t.wb(i).is-ignorable then t.next-real(pretend-decreasing(i + 1)) else i

// The number of regional indicators in a row ending at `i` (ignoring WB4 characters).
fun ri-count( t : wtext, i : int ) : int
  if i < 0 || t.wb(i) != wRI then 0 else 1 + t.ri-count(pretend-decreasing(t.prev-real(i - 1)))

// WB3 to WB4: `Just(is-break)` if one of these rules applies.
fun word-break-basic( a : int, b : int, b-pict : bool ) : maybe<bool>
  if a == wCR && b == wLF then Just(False)                         // WB3
  elif a == wNewline || a == wCR || a == wLF then Just(True)       // WB3a
  elif b == wNewline || b == wCR || b == wLF then Just(True)       // WB3b
  elif a == wZWJ && b-pict then Just(False)                        // WB3c
  elif a == wWSegSpace && b == wWSegSpace then Just(False)         // WB3d
  elif b.is-ignorable then Just(False)                             // WB4
  else Nothing

// The rules WB5 to WB13b, each on `a2 a1 | b c` around the position
// (ignoring WB4 characters); they keep the characters together. (Each is
// a separate function: one long chain of `||` and `&&` takes the compiler
// exponential time.)
fun wb5( a1 : int, b : int ) : bool
  a1.is-ahletter && b.is-ahletter

fun is-midletterq( w : int ) : bool
  w == wMidLetter || w.is-midnumletq

fun wb6( a1 : int, b : int, c : int ) : bool
  a1.is-ahletter && b.is-midletterq && c.is-ahletter

fun wb7( a2 : int, a1 : int, b : int ) : bool
  a2.is-ahletter && a1.is-midletterq && b.is-ahletter

fun wb7a( a1 : int, b : int ) : bool
  a1 == wHebrew && b == wSingleQuote

fun wb7b( a1 : int, b : int, c : int ) : bool
  a1 == wHebrew && b == wDoubleQuote && c == wHebrew

fun wb7c( a2 : int, a1 : int, b : int ) : bool
  a2 == wHebrew && a1 == wDoubleQuote && b == wHebrew

fun wb8to10( a1 : int, b : int ) : bool
  val an = a1 == wNumeric
  val bn = b == wNumeric
  (an && bn) || (a1.is-ahletter && bn) || (an && b.is-ahletter)

fun is-midnumq( w : int ) : bool
  w == wMidNum || w.is-midnumletq

fun wb11( a2 : int, a1 : int, b : int ) : bool
  a2 == wNumeric && a1.is-midnumq && b == wNumeric

fun wb12( a1 : int, b : int, c : int ) : bool
  a1 == wNumeric && b.is-midnumq && c == wNumeric

fun wb13( a1 : int, b : int ) : bool
  a1 == wKatakana && b == wKatakana

fun is-word-like( w : int ) : bool
  w.is-ahletter || w == wNumeric || w == wKatakana

fun wb13ab( a1 : int, b : int ) : bool
  ((a1.is-word-like || a1 == wExtendNumLet) && b == wExtendNumLet) || (a1 == wExtendNumLet && b.is-word-like)

fun word-keep( a2 : int, a1 : int, b : int, c : int ) : bool
  if wb5(a1, b) then True
  elif wb6(a1, b, c) then True
  elif wb7(a2, a1, b) then True
  elif wb7a(a1, b) then True
  elif wb7b(a1, b, c) then True
  elif wb7c(a2, a1, b) then True
  elif wb8to10(a1, b) then True
  elif wb11(a2, a1, b) then True
  elif wb12(a1, b, c) then True
  elif wb13(a1, b) then True
  else wb13ab(a1, b)

// Is there a word boundary between `i - 1` and `i`?
fun word-break( t : wtext, i : int ) : bool
  val a = t.wb(i - 1)
  val b = t.wb(i)
  match word-break-basic(a, b, t.is-pict(i))
    Just(is-brk) -> is-brk
    Nothing ->
      val j = t.prev-real(i - 1)
      val wj = t.wb(j)
      val a1 = if j < 0 || wj == wNewline || wj == wCR || wj == wLF then a else wj
      val a2 = if j < 0 then -1 else t.wb(t.prev-real(j - 1))
      val c = t.wb(t.next-real(i + 1))
      if word-keep(a2, a1, b, c) then False
      elif a1 == wRI && b == wRI && t.ri-count(j) % 2 == 1 then False                // WB15, WB16
      else True                                                                       // WB999

fun word-collect( t : wtext, i : int, start : int, acc : list<string> ) : list<string>
  val n = t.length
  if i >= n then (if start < n then Cons(slice-string(t.chars, start, n), acc) else acc).reverse
  elif t.word-break(i) then t.word-collect(pretend-decreasing(i + 1), i, Cons(slice-string(t.chars, start, i), acc))
  else t.word-collect(pretend-decreasing(i + 1), start, acc)

// Split a string into its word segments: words, numbers, spaces and
// punctuation (UAX #29). Concatenating them gives back the string.
pub fun word-segments( s : string ) : list<string>
  val cs = s.vector
  val table = word-table.force
  val t = Wtext(cs, cs.map(fn(c) table.lookup(c.int)))
  if t.length == 0 then [] else t.word-collect(1, 0, [])

fun slice-string( cs : vector<char>, from : int, to : int ) : string
  list(from, to - 1).map(fn(i) cs.at(i).default(' ')).string

// The words of a string: the word segments that contain a letter or a digit.
pub fun words( s : string ) : list<string>
  s.word-segments.filter(fn(w) w.list.any(fn(c) (word-table.force.lookup(c.int) / 64) % 2 == 1))

// ----------------------------------------------------------------------------
// Display width
// ----------------------------------------------------------------------------

// The number of terminal columns a character takes (like `wcwidth`): 0 for
// combining marks, format and control characters, 2 for wide characters
// (East Asian wide and fullwidth, and most emoji), and 1 otherwise.
pub fun char/width( c : char ) : int
  match width-table.force.lookup(c.int)
    1 -> 0
    2 -> 2
    _ -> 1

// The number of terminal columns a grapheme takes: the width of its first
// character, but 2 for an emoji with a presentation selector (U+FE0F) and
// for a flag.
pub fun grapheme-width( g : grapheme ) : int
  match g.list
    Nil -> 0
    Cons(c, rest) ->
      val w = c.width
      if w == 1 && ((c.gprops / 16) % 2 == 1 && rest.any(fn(x) x.int == 0xFE0F) || (c.gprops % 16 == gRI && !rest.is-nil)) then 2
      else w

// The number of terminal columns a string takes (the sum of the widths of its graphemes).
pub fun string/width( s : string ) : int
  s.graphemes.foldl(0, fn(n, g) n + g.grapheme-width)

// ----------------------------------------------------------------------------
// Case folding
// ----------------------------------------------------------------------------

// Sorted code points with their full case folding.
struct folds( keys : vector<int>, targets : vector<string> )

val fold-table : delayed<total,folds> = delay
  val entries = case-folds.split(",").map fn(e)
    match e.trim.split("=")
      [k, v] -> (k.trim.parse-hex, v.split(" ").map(fn(x) x.trim.parse-hex.char).string)
      _ -> (-1, "")
  Folds(entries.map(fst).vector, entries.map(snd).vector)

fun parse-hex( s : string ) : int
  s.list.foldl(0, fn(n, c) if c == '\n' then n else n * 16 + c.hex-digit)

fun fold-char( c : char ) : string
  val t = fold-table.force
  fun go( lo : int, hi : int ) : string
    if lo >= hi then c.string
    else
      val mid = (lo + hi) / 2
      val k = t.keys.at0(mid)
      if c.int < k then go(lo, pretend-decreasing(mid))
      elif c.int > k then go(pretend-decreasing(mid + 1), hi)
      else t.targets.at(mid).default(c.string)
  go(0, t.keys.length)

// Full Unicode case folding: map a string to a form in which case
// differences are removed (`"Straße"` and `"STRASSE"` both become
// `"strasse"`), for comparing strings without regard to case.
pub fun fold-case( s : string ) : string
  s.list.map(fold-char).join

// Are two strings equal when case differences are ignored (by case folding)?
pub fun equals-ignore-case( a : string, b : string ) : bool
  a.fold-case == b.fold-case

// ----------------------------------------------------------------------------
// Normalization
// ----------------------------------------------------------------------------

// Unicode [normalization](https://www.unicode.org/reports/tr15) forms.
pub type normalization
  // Canonical composition (default). Use composed characters when possible.
  NFC
  // Canonical decomposition.
  NFD
  // Compatibility composition.
  NFKC
  // Compatibility decomposition.
  NFKD

// The decomposition mappings, and the canonical compositions of pairs.
struct decomps
  keys : vector<int>
  compats : vector<bool>
  targets : vector<list<int>>
  pair-keys : vector<int>      // first * 0x110000 + second, sorted
  pair-values : vector<int>

val decomp-table : delayed<total,decomps> = delay
  val entries = decompositions.split(",").map fn(e)
    val t = e.trim.replace-all("\n", "")
    match t.find("~")
      Just(sl) -> (sl.before.string.parse-hex, True, False, sl.after.string.split(" ").map(parse-hex))
      Nothing -> match t.find("=")
        Just(sl) ->
          val rhs = sl.after.string
          val excluded = rhs.starts-with("!").is-just
          val body = if excluded then rhs.slice.drop(1).string else rhs
          (sl.before.string.parse-hex, False, excluded, body.split(" ").map(parse-hex))
        Nothing -> (-1, False, True, [])
  val pairs = entries.filter-map fn((k, compat, excluded, ts))
    match ts
      [a, b] | !compat && !excluded -> Just((a * 0x110000 + b, k))
      _ -> Nothing
  val sorted = pairs.sort-by(fn(x, y) cmp(x.fst, y.fst))
  Decomps(entries.map(fn((k, _, _, _)) k).vector, entries.map(fn((_, c, _, _)) c).vector,
          entries.map(fn((_, _, _, ts)) ts).vector, sorted.map(fst).vector, sorted.map(snd).vector)

fun search( keys : vector<int>, k : int ) : int
  fun go( lo : int, hi : int ) : int
    if lo >= hi then -1
    else
      val mid = (lo + hi) / 2
      val x = keys.at0(mid)
      if k < x then go(lo, pretend-decreasing(mid))
      elif k > x then go(pretend-decreasing(mid + 1), hi)
      else mid
  go(0, keys.length)

val sBase = 0xAC00
val lBase = 0x1100
val vBase = 0x1161
val tBase = 0x11A7
val lCount = 19
val vCount = 21
val tCount = 28
val nCount = 588     // vCount * tCount
val sCount = 11172   // lCount * nCount

fun ccc( cp : int ) : int
  ccc-table.force.lookup(cp)

// The full decomposition of `cp`.
fun decompose( cp : int, compat : bool ) : list<int>
  val s = cp - sBase
  if s >= 0 && s < sCount then
    val l = lBase + s / nCount
    val v = vBase + (s % nCount) / tCount
    val t = tBase + s % tCount
    if t == tBase then [l, v] else [l, v, t]
  else
    val d = decomp-table.force
    val i = search(d.keys, cp)
    if i < 0 || (d.compats.at(i).default(False) && !compat) then [cp]
    else d.targets.at(i).default([cp]).flatmap(fn(x) decompose(pretend-decreasing(x), compat))

// Sort runs of non-starters by combining class (stably).
fun canonical-order( cps : list<int> ) : list<int>
  fun flush( run : list<(int, int)> ) : list<int>
    // `run` is reversed; the result is reversed too (it is prepended to `acc`)
    run.reverse.sort-by(fn(a, b) cmp(a.fst, b.fst)).map(snd).reverse
  fun go( xs : list<int>, run : list<(int, int)>, acc : list<int> ) : list<int>
    match xs
      Nil -> (flush(run) ++ acc).reverse
      Cons(x, rest) ->
        val c = ccc(x)
        if c == 0 then go(rest, [], Cons(x, flush(run) ++ acc))
        else go(rest, Cons((c, x), run), acc)
  go(cps, [], [])

// The canonical composition of `a` and `b`, if any.
fun compose-pair( a : int, b : int ) : maybe<int>
  val l = a - lBase
  val sidx = a - sBase
  if l >= 0 && l < lCount && b >= vBase && b < vBase + vCount then
    Just(sBase + (l * vCount + (b - vBase)) * tCount)
  elif sidx >= 0 && sidx < sCount && sidx % tCount == 0 && b > tBase && b < tBase + tCount then
    Just(a + (b - tBase))
  else
    val d = decomp-table.force
    val i = search(d.pair-keys, a * 0x110000 + b)
    if i < 0 then Nothing else d.pair-values.at(i)

// The canonical composition algorithm.
fun compose( cps : list<int> ) : list<int>
  // `starter` is the last starter (if it can still compose), `between` the
  // non-starters after it (reversed), and `last` the class of the last of them
  fun go( xs : list<int>, starter : maybe<int>, between : list<int>, last : int, acc : list<int> ) : list<int>
    match xs
      Nil -> (between ++ starter.list ++ acc).reverse
      Cons(x, rest) ->
        val c = ccc(x)
        match starter
          Nothing ->
            if c == 0 then go(rest, Just(x), [], 0, acc) else go(rest, Nothing, [], 0, Cons(x, acc))
          Just(s) ->
            val blocked = !between.is-nil && (last == 0 || last >= c)
            match (if blocked then Nothing else compose-pair(s, x))
              Just(p) -> go(rest, Just(p), between, last, acc)
              Nothing ->
                if c == 0 then go(rest, Just(x), [], 0, between ++ Cons(s, acc))
                else go(rest, starter, Cons(x, between), c, acc)
  go(cps, Nothing, [], 0, [])

// Normalize a string to one of the Unicode normalization forms (`NFC` by default).
pub fun normalize( s : string, norm : normalization = NFC ) : string
  val compat = match norm
    NFKC -> True
    NFKD -> True
    _ -> False
  val decomposed = canonical-order(s.list.flatmap(fn(c) decompose(c.int, compat)))
  val result = match norm
    NFC -> compose(decomposed)
    NFKC -> compose(decomposed)
    _ -> decomposed
  result.map(char).string
