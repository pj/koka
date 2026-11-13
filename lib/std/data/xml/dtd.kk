/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* XML validation against a DTD.

   ```
   import std/data/xml
   import std/data/xml/dtd

   fun main()
     val doc = parse-valid-xml(r#"<!DOCTYPE note [
         <!ELEMENT note (to+, body)>
         <!ELEMENT to (#PCDATA)>
         <!ELEMENT body (#PCDATA)>
         <!ATTLIST note priority (low|high) "low">
       ]>
       <note><to>Ann</to><body>Hi</body></note>"#)
     println(doc.attr("priority"))   // Just("low"), from the default
   ```

   `parse-dtd` reads DTD declarations: element declarations (`EMPTY`, `ANY`,
   mixed content and content models with `,`, `|`, `?`, `*` and `+`),
   attribute lists (all attribute types and defaults), and parameter
   entities and conditional sections (`INCLUDE`/`IGNORE`). General entity and
   notation declarations are skipped (`std/data/xml` uses the internal general
   entities). `validate` checks a document against a DTD and returns the
   errors: undeclared elements and attributes, content that does not match
   its model, missing required attributes, `#FIXED` values, attribute values
   of the wrong type, duplicate IDs, and IDREFs to IDs that do not exist.

   External DTDs are never loaded: pass their text to `parse-valid-xml` (or
   to `parse-dtd`) if the document needs one.
*/
module std/data/xml/dtd

import std/core/undiv
import std/data/xml

// How often a part of a content model may occur.
pub type occurs
  Once
  Optional   // `?`
  Many       // `*`
  Repeated   // `+`

// A content model.
pub type particle
  // An element name.
  Child( name : string, occurs : occurs )
  // `(a, b, c)`
  Sequence( items : list<particle>, occurs : occurs )
  // `(a | b | c)`
  Choice( items : list<particle>, occurs : occurs )

// What an element may contain.
pub type content-spec
  Empty-content
  Any-content
  // `(#PCDATA | a | b)*`: text and the given elements, in any order
  Mixed( names : list<string> )
  // child elements matching a content model (and whitespace)
  Children( model : particle )

pub type attr-type
  Cdata-type
  Id-type
  Idref-type
  Idrefs-type
  Entity-type
  Entities-type
  Nmtoken-type
  Nmtokens-type
  Enumerated( values : list<string> )
  Notation-type( names : list<string> )

pub type attr-default
  Required
  Implied
  Fixed( value : string )
  Default-value( value : string )

// An attribute declaration from an `<!ATTLIST>`.
pub struct attr-decl
  element : string
  name : string
  atype : attr-type
  default : attr-default

// The declarations of a DTD. (The first declaration of an element or
// attribute counts, as in XML.)
pub struct dtd
  elements : list<(string, content-spec)>
  attributes : list<attr-decl>

// ----------------------------------------------------------------------------
// Parsing
// ----------------------------------------------------------------------------

fun dtd-error( msg : string, cs : list<char> ) : exn a
  val near = cs.take(40).string
  throw("dtd: " ++ msg ++ (if near.is-empty then " at the end" else " near " ++ near.show))

fun is-ws( c : char ) : bool
  c == ' ' || c == '\t' || c == '\n' || c == '\r'

fun skip-ws( cs : list<char> ) : list<char>
  match cs
    Cons(c, rest) | c.is-ws -> rest.skip-ws
    _ -> cs

fun starts( cs : list<char>, s : string ) : bool
  cs.take(s.count).string == s

fun skip-past( cs : list<char>, stop : string ) : exn list<char>
  if cs.starts(stop) then cs.drop(stop.count)
  else match cs
    Cons(_, rest) -> rest.skip-past(stop)
    Nil -> dtd-error("expected " ++ stop.show, cs)

fun is-name-start( c : char ) : bool
  c.is-alpha || c == '_' || c == ':' || c.int >= 0x80

fun is-name-char( c : char ) : bool
  c.is-name-start || c.is-digit || c == '-' || c == '.'

// A declaration's text up to its closing `>` (quotes respected), and the rest.
fun decl-text( cs : list<char> ) : exn (list<char>, list<char>)
  fun go( xs : list<char>, acc : list<char> ) : exn (list<char>, list<char>)
    match xs
      Cons('>', rest) -> (acc.reverse, rest)
      Cons(q, rest) | q == '"' || q == '\'' ->
        val lit = rest.take-while(fn(c) c != q)
        val after = rest.drop(lit.length)
        if after.is-nil then dtd-error("unterminated literal", xs)
        go(pretend-decreasing(after.drop(1)), Cons(q, lit.reverse ++ Cons(q, acc)))
      Cons(c, rest) -> go(rest, Cons(c, acc))
      Nil -> dtd-error("unterminated declaration", cs)
  go(cs, [])

// The most characters that parameter entity references may expand to.
val max-expansion = 1000000

// Replace parameter entity references `%name;` (outside literals).
fun expand-pes( cs : list<char>, pes : list<(string, string)>, budget : int ) : exn (list<char>, int)
  fun go( xs : list<char>, acc : list<char>, left : int ) : exn (list<char>, int)
    match xs
      Cons('%', rest) | rest.head.map(is-name-start).default(False) ->
        val name = rest.take-while(is-name-char)
        match rest.drop(name.length)
          Cons(';', after) ->
            match pes.lookup(fn(n) n == name.string)
              Just(v) ->
                val left' = left - v.count
                if left' < 0 then dtd-error("parameter entity expansion limit exceeded", xs)
                // the replacement text is padded with spaces (XML section 4.4.8)
                go(pretend-decreasing([' '] ++ v.list ++ [' '] ++ after), acc, left')
              Nothing -> dtd-error("undeclared parameter entity %" ++ name.string ++ ";", xs)
          _ -> go(rest, Cons('%', acc), left)
      Cons(q, rest) | q == '"' || q == '\'' ->
        val lit = rest.take-while(fn(c) c != q)
        go(pretend-decreasing(rest.drop(lit.length + 1)), Cons(q, lit.reverse ++ Cons(q, acc)), left)
      Cons(c, rest) -> go(rest, Cons(c, acc), left)
      Nil -> (acc.reverse, left)
  go(cs, [], budget)

// Expand parameter entity references inside an entity value (literals included).
fun expand-pes-in-value( v : string, pes : list<(string, string)> ) : exn string
  fun go( xs : list<char>, acc : list<char> ) : exn list<char>
    match xs
      Cons('%', rest) | rest.head.map(is-name-start).default(False) ->
        val name = rest.take-while(is-name-char)
        match rest.drop(name.length)
          Cons(';', after) -> match pes.lookup(fn(n) n == name.string)
            Just(x) -> go(pretend-decreasing(after), x.list.reverse ++ acc)
            Nothing -> dtd-error("undeclared parameter entity %" ++ name.string ++ ";", xs)
          _ -> go(rest, Cons('%', acc))
      Cons(c, rest) -> go(rest, Cons(c, acc))
      Nil -> acc.reverse
  go(v.list, []).string

// Replace the predefined entities and character references in a literal.
fun unescape-literal( s : string ) : exn string
  fun go( xs : list<char>, acc : list<char> ) : exn list<char>
    match xs
      Cons('&', rest) ->
        val name = rest.take-while(fn(c) c != ';')
        val after = rest.drop(name.length + 1)
        val c = match name.string
          "lt" -> '<'
          "gt" -> '>'
          "amp" -> '&'
          "quot" -> '"'
          "apos" -> '\''
          n ->
            val code = if n.starts-with("#x").is-just then n.slice.drop(2).string.parse-int(hex = True)
                       elif n.starts-with("#").is-just then n.slice.drop(1).string.parse-int
                       else Nothing
            match code
              Just(i) -> i.char
              Nothing -> dtd-error("unsupported reference &" ++ n ++ "; in a default value", xs)
        go(pretend-decreasing(after), Cons(c, acc))
      Cons(c, rest) -> go(rest, Cons(c, acc))
      Nil -> acc.reverse
  go(s.list, []).string

// Parse DTD declarations: an internal subset, or the text of an external DTD.
pub fun parse-dtd( text : string ) : exn dtd
  val (els, atts) = decls(text.list, [], 0, [], [], max-expansion)
  Dtd(els.reverse, atts.reverse)

// `includes`: the number of open `INCLUDE` sections.
fun decls( cs : list<char>, pes : list<(string, string)>, includes : int,
           els : list<(string, content-spec)>, atts : list<attr-decl>, budget : int ) : exn (list<(string, content-spec)>, list<attr-decl>)
  val c1 = cs.skip-ws
  if c1.is-nil then
    if includes > 0 then dtd-error("unterminated INCLUDE section", c1)
    (els, atts)
  elif c1.starts("<!--") then decls(pretend-decreasing(c1.drop(4).skip-past("-->")), pes, includes, els, atts, budget)
  elif c1.starts("<?") then decls(pretend-decreasing(c1.drop(2).skip-past("?>")), pes, includes, els, atts, budget)
  elif c1.starts("]]>") && includes > 0 then decls(pretend-decreasing(c1.drop(3)), pes, includes - 1, els, atts, budget)
  elif c1.starts("%") then
    // a parameter entity reference between declarations
    val name = c1.drop(1).take-while(is-name-char)
    match c1.drop(1 + name.length)
      Cons(';', after) -> match pes.lookup(fn(n) n == name.string)
        Just(v) ->
          if budget < v.count then dtd-error("parameter entity expansion limit exceeded", c1)
          decls(pretend-decreasing(v.list ++ after), pes, includes, els, atts, budget - v.count)
        Nothing -> dtd-error("undeclared parameter entity %" ++ name.string ++ ";", c1)
      _ -> dtd-error("invalid parameter entity reference", c1)
  elif c1.starts("<![") then
    // a conditional section: its keyword may be a parameter entity reference
    val (kw-text, _) = expand-pes(c1.drop(3).take-while(fn(c) c != '['), pes, budget)
    val kw = kw-text.string.trim
    val body = c1.drop(3).drop-while(fn(c) c != '[').drop(1)
    if kw == "INCLUDE" then decls(pretend-decreasing(body), pes, includes + 1, els, atts, budget)
    elif kw == "IGNORE" then decls(pretend-decreasing(skip-ignored(body, 0)), pes, includes, els, atts, budget)
    else dtd-error("expected INCLUDE or IGNORE", c1)
  elif c1.starts("<!ENTITY") then
    val (d, rest) = decl-text(c1.drop(8))
    val d1 = d.skip-ws
    match d1
      Cons('%', d2) ->
        val (name, d3) = parse-name(d2.skip-ws)
        val pes' = match d3.skip-ws
          Cons(q, lit) | (q == '"' || q == '\'') && !pes.any(fn((n, _)) n == name) ->
            val v = lit.take-while(fn(c) c != q).string
            pes ++ [(name, expand-pes-in-value(v, pes))]
          _ -> pes   // an external parameter entity (not loaded), or a second declaration
        decls(pretend-decreasing(rest), pes', includes, els, atts, budget)
      _ -> decls(pretend-decreasing(rest), pes, includes, els, atts, budget)   // general entities: see std/data/xml
  elif c1.starts("<!NOTATION") then
    val (_, rest) = decl-text(c1.drop(10))
    decls(pretend-decreasing(rest), pes, includes, els, atts, budget)
  elif c1.starts("<!ELEMENT") then
    val (d, rest) = decl-text(c1.drop(9))
    val (d', budget') = expand-pes(d, pes, budget)
    val (name, spec) = parse-element(tokenize(d'))
    if els.any(fn((n, _)) n == name) then dtd-error("element " ++ name ++ " is declared twice", c1)
    decls(pretend-decreasing(rest), pes, includes, Cons((name, spec), els), atts, budget')
  elif c1.starts("<!ATTLIST") then
    val (d, rest) = decl-text(c1.drop(9))
    val (d', budget') = expand-pes(d, pes, budget)
    val new = parse-attlist(tokenize(d'))
    // the first declaration of an attribute counts
    val atts' = new.foldl(atts, fn(acc, a) if acc.any(fn(b) b.element == a.element && b.name == a.name) then acc else Cons(a, acc))
    decls(pretend-decreasing(rest), pes, includes, els, atts', budget')
  else dtd-error("expected a declaration", c1)

// Skip an IGNORE section (which may contain nested sections).
fun skip-ignored( cs : list<char>, depth : int ) : exn list<char>
  if cs.starts("<![") then skip-ignored(pretend-decreasing(cs.drop(3)), depth + 1)
  elif cs.starts("]]>") then
    if depth == 0 then cs.drop(3) else skip-ignored(pretend-decreasing(cs.drop(3)), depth - 1)
  else match cs
    Cons(_, rest) -> skip-ignored(rest, depth)
    Nil -> dtd-error("unterminated IGNORE section", cs)

fun parse-name( cs : list<char> ) : exn (string, list<char>)
  match cs
    Cons(c, _) | c.is-name-start ->
      val n = cs.take-while(is-name-char)
      (n.string, cs.drop(n.length))
    _ -> dtd-error("expected a name", cs)

type token
  Word( s : string )      // a name, a name token, or a keyword like `#PCDATA`
  Punct( c : char )
  Quoted( s : string )

fun token/show( t : token ) : string
  match t
    Word(s) -> s
    Punct(c) -> c.string
    Quoted(s) -> s.show

fun tokenize( cs : list<char> ) : exn list<token>
  match cs.skip-ws
    Nil -> Nil
    Cons(q, rest) | q == '"' || q == '\'' ->
      val lit = rest.take-while(fn(c) c != q)
      Cons(Quoted(lit.string), tokenize(pretend-decreasing(rest.drop(lit.length + 1))))
    Cons(c, rest) | c.is-name-char || c == '#' ->
      val w = rest.take-while(is-name-char)
      Cons(Word(Cons(c, w).string), tokenize(pretend-decreasing(rest.drop(w.length))))
    Cons(c, rest) | c == '(' || c == ')' || c == '|' || c == ',' || c == '?' || c == '*' || c == '+' ->
      Cons(Punct(c), tokenize(pretend-decreasing(rest)))
    xs -> dtd-error("unexpected character", xs)

fun tok-error( msg : string, ts : list<token> ) : exn a
  throw("dtd: " ++ msg ++ (if ts.is-nil then " at the end of a declaration" else " at " ++ ts.take(6).map(show).join(" ").show))

fun parse-element( ts : list<token> ) : exn (string, content-spec)
  match ts
    Cons(Word(name), rest) ->
      val spec = match rest
        [Word("EMPTY")] -> Empty-content
        [Word("ANY")] -> Any-content
        Cons(Punct('('), Cons(Word("#PCDATA"), more)) -> parse-mixed(more, [])
        _ -> match pretend-no-div(fn() parse-particle(rest))
          (p, []) -> match p
            Child(_, _) -> tok-error("a content model must be in parentheses", rest)
            _ -> Children(p)
          (_, extra) -> tok-error("unexpected", extra)
      (name, spec)
    _ -> tok-error("expected an element name", ts)

fun parse-mixed( ts : list<token>, names : list<string> ) : exn content-spec
  match ts
    Cons(Punct('|'), Cons(Word(n), rest)) -> parse-mixed(rest, Cons(n, names))
    [Punct(')')] | names.is-nil -> Mixed([])
    [Punct(')'), Punct('*')] -> Mixed(names.reverse)
    _ -> tok-error("invalid mixed content", ts)

fun parse-occurs( ts : list<token> ) : (occurs, list<token>)
  match ts
    Cons(Punct('?'), rest) -> (Optional, rest)
    Cons(Punct('*'), rest) -> (Many, rest)
    Cons(Punct('+'), rest) -> (Repeated, rest)
    _ -> (Once, ts)

fun parse-particle( ts : list<token> ) : <div,exn> (particle, list<token>)
  match ts
    Cons(Word(n), rest) | !n.starts-with("#").is-just ->
      val (o, rest') = parse-occurs(rest)
      (Child(n, o), rest')
    Cons(Punct('('), rest) ->
      val (first, rest1) = parse-particle(rest)
      val (items, sep, rest2) = parse-group(rest1, [first], ' ')
      val (o, rest3) = parse-occurs(rest2)
      (if sep == '|' then Choice(items, o) else Sequence(items, o), rest3)
    _ -> tok-error("expected a content particle", ts)

// The rest of a group after its first particle: the particles, the separator, and the rest after `)`.
fun parse-group( ts : list<token>, acc : list<particle>, sep : char ) : <div,exn> (list<particle>, char, list<token>)
  match ts
    Cons(Punct(')'), rest) -> (acc.reverse, sep, rest)
    Cons(Punct(c), rest) | (c == ',' || c == '|') && (sep == ' ' || sep == c) ->
      val (p, rest1) = parse-particle(rest)
      parse-group(pretend-decreasing(rest1), Cons(p, acc), c)
    _ -> tok-error("expected ',', '|' or ')' in a content model", ts)

fun parse-attlist( ts : list<token> ) : exn list<attr-decl>
  match ts
    Cons(Word(element), rest) -> parse-attdefs(element, rest, [])
    _ -> tok-error("expected an element name", ts)

fun parse-attdefs( element : string, ts : list<token>, acc : list<attr-decl> ) : exn list<attr-decl>
  match ts
    Nil -> acc.reverse
    Cons(Word(name), rest) ->
      val (atype, rest1) = match rest
        Cons(Word("CDATA"), r) -> (Cdata-type, r)
        Cons(Word("ID"), r) -> (Id-type, r)
        Cons(Word("IDREF"), r) -> (Idref-type, r)
        Cons(Word("IDREFS"), r) -> (Idrefs-type, r)
        Cons(Word("ENTITY"), r) -> (Entity-type, r)
        Cons(Word("ENTITIES"), r) -> (Entities-type, r)
        Cons(Word("NMTOKEN"), r) -> (Nmtoken-type, r)
        Cons(Word("NMTOKENS"), r) -> (Nmtokens-type, r)
        Cons(Word("NOTATION"), Cons(Punct('('), r)) ->
          val (vs, r') = parse-enumeration(r, [])
          (Notation-type(vs), r')
        Cons(Punct('('), r) ->
          val (vs, r') = parse-enumeration(r, [])
          (Enumerated(vs), r')
        _ -> tok-error("expected an attribute type", rest)
      val (default, rest2) = match rest1
        Cons(Word("#REQUIRED"), r) -> (Required, r)
        Cons(Word("#IMPLIED"), r) -> (Implied, r)
        Cons(Word("#FIXED"), Cons(Quoted(v), r)) -> (Fixed(v.unescape-literal.normalize-space(atype)), r)
        Cons(Quoted(v), r) -> (Default-value(v.unescape-literal.normalize-space(atype)), r)
        _ -> tok-error("expected an attribute default", rest1)
      parse-attdefs(element, pretend-decreasing(rest2), Cons(Attr-decl(element, name, atype, default), acc))
    _ -> tok-error("expected an attribute name", ts)

fun parse-enumeration( ts : list<token>, acc : list<string> ) : exn (list<string>, list<token>)
  match ts
    Cons(Word(v), Cons(Punct('|'), rest)) -> parse-enumeration(rest, Cons(v, acc))
    Cons(Word(v), Cons(Punct(')'), rest)) -> (Cons(v, acc).reverse, rest)
    _ -> tok-error("invalid enumeration", ts)

// Attribute values of the tokenized types are normalized: leading and
// trailing spaces dropped, inner runs of spaces collapsed.
fun normalize-space( v : string, atype : attr-type ) : string
  match atype
    Cdata-type -> v
    _ -> v.split(" ").filter(fn(t) !t.is-empty).join(" ")

// ----------------------------------------------------------------------------
// Validation
// ----------------------------------------------------------------------------

// Check a document (its root element) against a DTD; returns the validity
// errors, in document order (an empty list if the document is valid). With
// a `root` name (from the DOCTYPE), the root element must have that name.
pub fun validate( doc : xml, d : dtd, root : string = "" ) : list<string>
  val root-errors = if !root.is-empty && doc.tag != root then
      ["the root element is <" ++ doc.tag ++ ">, but the DOCTYPE names <" ++ root ++ ">"]
    else []
  // all IDs first: an IDREF may refer forward
  val ids = doc.collect-ids(d)
  val dup-errors = ids.dups.map(fn(i) "the ID " ++ i.show ++ " is used more than once")
  root-errors ++ dup-errors ++ doc.check-element(d, ids)

fun dups( xs : list<string> ) : list<string>
  match xs
    Cons(x, rest) -> if rest.any(fn(y) y == x) then Cons(x, pretend-decreasing(rest.filter(fn(y) y != x)).dups) else rest.dups
    Nil -> Nil

fun decls-of( d : dtd, el : string ) : list<attr-decl>
  d.attributes.filter(fn(a) a.element == el)

fun collect-ids( x : xml, d : dtd ) : list<string>
  match x
    Element(n, attrs, cs) ->
      val own = d.decls-of(n).filter-map fn(a)
        match a.atype
          Id-type -> attrs.lookup(fn(k) k == a.name).map(fn(v) v.normalize-space(Id-type))
          _ -> Nothing
      own ++ cs.flatmap(fn(c) pretend-decreasing(c).collect-ids(d))
    _ -> []

fun check-element( x : xml, d : dtd, ids : list<string> ) : list<string>
  match x
    Element(n, attrs, cs) ->
      val here = "<" ++ n ++ ">: "
      val own = match d.elements.lookup(fn(e) e == n)
        Nothing -> ["element <" ++ n ++ "> is not declared"]
        Just(spec) -> check-content(spec, cs).map(fn(e) here ++ e) ++ check-attrs(n, attrs, d, ids).map(fn(e) here ++ e)
      own ++ cs.flatmap(fn(c) pretend-decreasing(c).check-element(d, ids))
    _ -> []

fun is-blank( s : string ) : bool
  s.list.all(is-ws)

fun check-content( spec : content-spec, cs : list<xml> ) : list<string>
  match spec
    Any-content -> []
    Empty-content -> if cs.is-nil then [] else ["the element must be empty"]
    Mixed(names) -> cs.filter-map fn(c)
      match c
        Element(m, _, _) | !names.any(fn(k) k == m) -> Just("<" ++ m ++ "> is not allowed here")
        _ -> Nothing
    Children(model) ->
      val text-errors = cs.filter-map fn(c)
        match c
          Text(t) | !t.is-blank -> Just("text is not allowed here")
          CData(_) -> Just("CDATA is not allowed here")
          _ -> Nothing
      val names = cs.filter-map(fn(c) match c { Element(m, _, _) -> Just(m); _ -> Nothing })
      val model-errors = if model.match-all(names) then []
                         else ["the children " ++ names.map(fn(m) "<" ++ m ++ ">").join(" ").default-if-empty("(none)") ++ " do not match " ++ model.show]
      text-errors ++ model-errors

fun default-if-empty( s : string, d : string ) : string
  if s.is-empty then d else s

// Does the content model match exactly these child element names?
fun match-all( p : particle, names : list<string> ) : bool
  pretend-no-div { p.match-rests(names).any(fn(r) r.is-nil) }

// The possible rests of `names` after `p` matches a prefix of it (each
// rest is a suffix of `names`, so suffixes with equal length are equal).
fun match-rests( p : particle, names : list<string> ) : div list<list<string>>
  match p.occurs
    Once -> p.match-once(names)
    Optional -> Cons(names, p.match-once(names)).nub-length
    Many -> p.closure([names], [names])
    Repeated -> val first = p.match-once(names) in p.closure(first, first)

// All rests reachable by repeating `p` from `frontier` (only rests that are
// shorter than the one they come from, so it stops).
fun closure( p : particle, frontier : list<list<string>>, seen : list<list<string>> ) : div list<list<string>>
  val next = frontier.flatmap(fn(r) p.match-once(r).filter(fn(r2) r2.length < r.length))
                     .filter(fn(r2) !seen.any(fn(s) s.length == r2.length)).nub-length
  if next.is-nil then seen else p.closure(next, seen ++ next)

fun match-once( p : particle, names : list<string> ) : div list<list<string>>
  match p
    Child(n, _) -> match names
      Cons(m, rest) | m == n -> [rest]
      _ -> []
    Sequence(items, _) -> items.foldl([names], fn(rests, item) rests.flatmap(fn(r) item.match-rests(r)).nub-length)
    Choice(items, _) -> items.flatmap(fn(item) item.match-rests(names)).nub-length

fun nub-length( rs : list<list<string>> ) : list<list<string>>
  match rs
    Cons(r, rest) -> Cons(r, pretend-decreasing(rest.filter(fn(s) s.length != r.length)).nub-length)
    Nil -> Nil

fun occurs/show( o : occurs ) : string
  match o
    Once -> ""
    Optional -> "?"
    Many -> "*"
    Repeated -> "+"

// The content model in DTD syntax.
pub fun particle/show( p : particle ) : string
  match p
    Child(n, o) -> n ++ o.show
    Sequence(items, o) -> "(" ++ items.map(fn(i) pretend-decreasing(i).show).join(", ") ++ ")" ++ o.show
    Choice(items, o) -> "(" ++ items.map(fn(i) pretend-decreasing(i).show).join(" | ") ++ ")" ++ o.show

fun is-name( s : string ) : bool
  match s.list
    Cons(c, rest) -> c.is-name-start && rest.all(is-name-char)
    Nil -> False

fun is-nmtoken( s : string ) : bool
  !s.is-empty && s.list.all(is-name-char)

fun check-attrs( el : string, attrs : list<(string, string)>, d : dtd, ids : list<string> ) : list<string>
  val decls = d.decls-of(el)
  val given = attrs.flatmap fn((k, v))
    match decls.find(fn(a) a.name == k)
      Nothing -> ["the attribute " ++ k ++ " is not declared"]
      Just(a) ->
        val nv = v.normalize-space(a.atype)
        val where = "the attribute " ++ k ++ "=" ++ v.show
        val type-errors = match a.atype
          Cdata-type -> []
          Id-type -> if nv.is-name then [] else [where ++ " is not a name"]
          Idref-type | !nv.is-name -> [where ++ " is not a name"]
          Idref-type -> if ids.any(fn(i) i == nv) then [] else [where ++ " refers to an ID that does not exist"]
          Idrefs-type ->
            val refs = nv.split(" ")
            if nv.is-empty || !refs.all(is-name) then [where ++ " is not a list of names"]
            else refs.filter(fn(r) !ids.any(fn(i) i == r)).map(fn(r) where ++ " refers to the ID " ++ r.show ++ ", which does not exist")
          Entity-type -> if nv.is-name then [] else [where ++ " is not a name"]
          Entities-type -> if !nv.is-empty && nv.split(" ").all(is-name) then [] else [where ++ " is not a list of names"]
          Nmtoken-type -> if nv.is-nmtoken then [] else [where ++ " is not a name token"]
          Nmtokens-type -> if !nv.is-empty && nv.split(" ").all(is-nmtoken) then [] else [where ++ " is not a list of name tokens"]
          Enumerated(vs) -> if vs.any(fn(x) x == nv) then [] else [where ++ " is not one of " ++ vs.join("|")]
          Notation-type(vs) -> if vs.any(fn(x) x == nv) then [] else [where ++ " is not one of " ++ vs.join("|")]
        val fixed-errors = match a.default
          Fixed(fv) | fv != nv -> [where ++ " must be " ++ fv.show]
          _ -> []
        type-errors ++ fixed-errors
  val missing = decls.filter-map fn(a)
    match a.default
      Required | !attrs.any(fn((k, _)) k == a.name) -> Just("the required attribute " ++ a.name ++ " is missing")
      _ -> Nothing
  given ++ missing

// Add the default values (and `#FIXED` values) of attributes that are not given.
pub fun add-defaults( x : xml, d : dtd ) : xml
  match x
    Element(n, attrs, cs) ->
      val extra = d.decls-of(n).filter-map fn(a)
        if attrs.any(fn((k, _)) k == a.name) then Nothing
        else match a.default
          Default-value(v) -> Just((a.name, v))
          Fixed(v) -> Just((a.name, v))
          _ -> Nothing
      Element(n, attrs ++ extra, cs.map(fn(c) pretend-decreasing(c).add-defaults(d)))
    _ -> x

// Parse a document and validate it against its DTD: the internal subset of its
// DOCTYPE, followed by `external` (the text of the external DTD, if the document
// needs one; it is never loaded). Raises an exception listing the errors if the
// document is not valid; otherwise returns the root element with the default
// attribute values added.
pub fun parse-valid-xml( s : string, external : string = "" ) : exn xml
  val doc = parse-xml(s)
  match parse-doctype(s)
    Nothing -> throw("xml: the document has no DOCTYPE to validate against")
    Just(dt) ->
      // the internal subset comes first, so its declarations take precedence
      val d = parse-dtd(dt.internal-subset ++ "\n" ++ external)
      match validate(doc, d, dt.name)
        Nil -> doc.add-defaults(d)
        errors -> throw("xml: the document is not valid: " ++ errors.join("; "))
