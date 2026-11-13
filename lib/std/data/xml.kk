/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* XML: a pull parser and a small document model.

   ```
   import std/data/xml

   fun main()
     val doc = parse-xml(r#"<feed><entry id="1"><title>Koka &amp; effects</title></entry><entry id="2"/></feed>"#)
     doc.elements("entry").foreach fn(e)
       println(e.attr("id").default("") ++ ": " ++ e.child("title").map(text-content).default("-"))
     println(doc.stringify)
   ```

   `xml-events` reads a document as a lazy sequence of events (start and end
   tags, text, ...), for documents that are too large to hold at once, and
   `parse-xml` builds the tree. Both check that the document is well formed
   (matching tags, one root element, unique attributes, and only the
   predefined entities `&lt; &gt; &amp; &quot; &apos;` and character
   references). The internal entity declarations of a DOCTYPE are used;
   `parse-doctype` gives the DOCTYPE itself, and `std/data/xml/dtd` validates
   a document against its DTD.
   Namespaces are not interpreted: a name like `atom:link` is kept as it is.
*/
module std/data/xml

import std/core/undiv
import std/core/seq
import std/text/builder

// A node of a document.
pub type xml
  // An element with its attributes and children.
  Element( name : string, attrs : list<(string, string)>, children : list<xml> )
  // Text (with entities replaced).
  Text( text : string )
  // A `<![CDATA[...]]>` section.
  CData( text : string )
  // A `<!-- comment -->`.
  Comment( text : string )
  // A processing instruction `<?target data?>`.
  Instruction( target : string, data : string )

// An event of the pull parser.
pub type xml-event
  Start-element( name : string, attrs : list<(string, string)> )
  End-element( name : string )
  Text-event( text : string )
  CData-event( text : string )
  Comment-event( text : string )
  Instruction-event( target : string, data : string )

// ----------------------------------------------------------------------------
// Access
// ----------------------------------------------------------------------------

// The value of attribute `key` of an element.
pub fun attr( x : xml, key : string ) : maybe<string>
  match x
    Element(_, attrs, _) -> attrs.lookup(fn(k) k == key)
    _ -> Nothing

// The attributes of an element (empty for other nodes).
pub fun attributes( x : xml ) : list<(string, string)>
  match x
    Element(_, attrs, _) -> attrs
    _ -> []

// The child elements named `name` (all child elements for `"*"`).
pub fun elements( x : xml, name : string = "*" ) : list<xml>
  match x
    Element(_, _, cs) -> cs.filter(fn(c) c.is-named(name))
    _ -> []

// The first child element named `name`.
pub fun child( x : xml, name : string ) : maybe<xml>
  x.elements(name).head

fun is-named( x : xml, name : string ) : bool
  match x
    Element(n, _, _) -> name == "*" || n == name
    _ -> False

// All elements named `name` in the tree, in document order (including `x` itself).
pub fun find-all( x : xml, name : string ) : list<xml>
  match x
    Element(_, _, cs) -> (if x.is-named(name) then [x] else []) ++ cs.flatmap(fn(c) pretend-decreasing(c).find-all(name))
    _ -> []

// The text of a node and all its descendants (text and CDATA, without comments).
pub fun text-content( x : xml ) : string
  match x
    Element(_, _, cs) -> cs.map(fn(c) pretend-decreasing(c).text-content).join
    Text(s) -> s
    CData(s) -> s
    _ -> ""

// The name of an element (`""` for other nodes).
pub fun tag( x : xml ) : string
  match x
    Element(n, _, _) -> n
    _ -> ""

// ----------------------------------------------------------------------------
// Writing
// ----------------------------------------------------------------------------

// Escape text for XML content or attribute values.
pub fun escape( s : string ) : string
  s.list.map(fn(c) match c { '<' -> "&lt;"; '>' -> "&gt;"; '&' -> "&amp;"; '"' -> "&quot;"; _ -> c.string }).join

// Write a node as XML text. With `indent` > 0, elements that contain only
// elements are written over several indented lines.
pub fun stringify( x : xml, indent : int = 0 ) : string
  pretend-no-div { build { emit-xml(x, indent, 0) } }

pub fun show( x : xml ) : string
  x.stringify

fun emit-xml( x : xml, indent : int, level : int ) : <emit,div> ()
  match x
    Text(s) -> emit(s.escape)
    CData(s) -> emit("<![CDATA[" ++ s ++ "]]>")
    Comment(s) -> emit("<!--" ++ s ++ "-->")
    Instruction(t, d) -> emit("<?" ++ t ++ (if d.is-empty then "" else " " ++ d) ++ "?>")
    Element(n, attrs, cs) ->
      emit("<" ++ n ++ attrs.map(fn((k, v)) " " ++ k ++ "=\"" ++ v.escape ++ "\"").join)
      if cs.is-nil then emit("/>")
      else
        emit(">")
        val block = indent > 0 && cs.all(fn(c) !c.is-text-like)
        cs.foreach fn(c)
          if block then emit("\n" ++ " ".repeat(indent * (level + 1)))
          emit-xml(c, indent, level + 1)
        if block then emit("\n" ++ " ".repeat(indent * level))
        emit("</" ++ n ++ ">")

fun is-text-like( x : xml ) : bool
  match x
    Text(_) -> True
    CData(_) -> True
    _ -> False

// ----------------------------------------------------------------------------
// Pull parser
// ----------------------------------------------------------------------------

fun parse-error( src : list<char>, rest : list<char>, msg : string ) : exn a
  val consumed = src.take(src.length - rest.length)
  val line = consumed.filter(fn(c) c == '\n').length + 1
  val col = consumed.reverse.take-while(fn(c) c != '\n').length + 1
  throw("xml parse error at line " ++ line.show ++ ", column " ++ col.show ++ ": " ++ msg)

// The parser state: the rest of the input, the open elements (innermost
// first), and whether the root element was seen.
struct pstate
  rest : list<char>
  open : list<string>
  seen-root : bool
  entities : list<(string, maybe<string>)> = []   // from the DOCTYPE; `Nothing` for an external entity
  expanded : int = 0                             // characters produced by entity expansion so far

// The most characters that entity references may expand to in one document
// (this stops recursive entities and "billion laughs" documents).
val max-expansion = 1000000

// The events of a document, as a lazy sequence. Errors are raised when the
// part of the document that has them is read.
pub fun xml-events( s : string ) : seq<<exn|e>,xml-event>
  val src = s.list
  seq/suspend(fn() event-step(src, Pstate(src.skip-prolog, [], False, [], 0)))

fun event-step( src : list<char>, st : pstate ) : <exn,div|e> step<<exn|e>,xml-event>
  match next-event(src, st)
    Nothing -> Done
    Just((ev, st1)) -> Yield(ev, seq/suspend(fn() event-step(src, pretend-decreasing(st1))))

fun is-ws( c : char ) : bool
  c == ' ' || c == '\t' || c == '\n' || c == '\r'

fun skip-ws( cs : list<char> ) : list<char>
  match cs
    Cons(c, rest) | c.is-ws -> rest.skip-ws
    _ -> cs

fun starts( cs : list<char>, start : string ) : bool
  cs.take(start.count).string == start

// The text up to `stop`, and the rest after it.
fun until( src : list<char>, cs : list<char>, stop : string, what : string ) : exn (string, list<char>)
  fun go( xs : list<char>, acc : list<char> ) : exn (string, list<char>)
    if xs.starts(stop) then (acc.reverse.string, xs.drop(stop.count))
    else match xs
      Cons(c, rest) -> go(rest, Cons(c, acc))
      Nil -> src.parse-error(cs, "unterminated " ++ what)
  go(cs, [])

// Skip the XML declaration and a DOCTYPE (with an internal subset) at the start.
fun skip-prolog( cs : list<char> ) : list<char>
  val cs1 = cs.drop-bom
  val cs2 = if cs1.starts("<?xml") && cs1.drop(5).head.map(is-ws).default(False) then cs1.skip-past("?>") else cs1
  cs2

fun drop-bom( cs : list<char> ) : list<char>
  match cs
    Cons(c, rest) | c.int == 0xFEFF -> rest
    _ -> cs

fun skip-past( cs : list<char>, stop : string ) : list<char>
  if cs.starts(stop) then cs.drop(stop.count)
  else match cs
    Cons(_, rest) -> rest.skip-past(stop)
    Nil -> Nil

// Skip `<!DOCTYPE ...>` with a possible `[...]` internal subset.
fun skip-doctype( src : list<char>, cs : list<char> ) : exn list<char>
  fun go( xs : list<char>, depth : int ) : exn list<char>
    match xs
      Cons('[', rest) -> go(rest, depth + 1)
      Cons(']', rest) -> go(rest, depth - 1)
      Cons('>', rest) | depth == 0 -> rest
      Cons('"', rest) -> go(pretend-decreasing(rest.skip-past("\"")), depth)
      Cons('\'', rest) -> go(pretend-decreasing(rest.skip-past("'")), depth)
      Cons(_, rest) -> go(rest, depth)
      Nil -> src.parse-error(cs, "unterminated DOCTYPE")
  go(cs, 0)

// The general entity declarations of a DOCTYPE (`<!ENTITY name "value">`;
// `SYSTEM`/`PUBLIC` ones are external and recorded as `Nothing`). Character
// references in values are replaced now; entity references when they are used.
// The first declaration of a name counts.
fun parse-entities( src : list<char>, at : list<char>, cs : list<char>, acc : list<(string, maybe<string>)> ) : exn list<(string, maybe<string>)>
  if cs.starts("<!--") then src.parse-entities(at, pretend-decreasing(cs.drop(4).skip-past("-->")), acc)
  elif cs.starts("<!ENTITY") then
    val d = cs.drop(8).skip-ws
    match d
      Cons('%', rest) -> src.parse-entities(at, pretend-decreasing(rest.skip-past(">")), acc)   // a parameter entity
      _ ->
        val (name, rest) = src.parse-name(d)
        val r = rest.skip-ws
        match r
          Cons(q, rest1) | q == '"' || q == '\'' ->
            val (value, rest2) = src.until(rest1, q.string, "entity value")
            val v = src.expand-char-refs(at, value)
            val acc1 = if acc.any(fn((n, _)) n == name) then acc else Cons((name, Just(v)), acc)
            src.parse-entities(at, pretend-decreasing(rest2.skip-past(">")), acc1)
          _ ->
            val acc1 = if acc.any(fn((n, _)) n == name) then acc else Cons((name, Nothing), acc)
            src.parse-entities(at, pretend-decreasing(r.skip-past(">")), acc1)
  else match cs
    Cons('"', rest) -> src.parse-entities(at, pretend-decreasing(rest.skip-past("\"")), acc)
    Cons('\'', rest) -> src.parse-entities(at, pretend-decreasing(rest.skip-past("'")), acc)
    Cons(_, rest) -> src.parse-entities(at, rest, acc)
    Nil -> acc.reverse

// The names of the entities that a value refers to.
fun entity-refs( v : string ) : list<string>
  fun go( xs : list<char>, acc : list<string> ) : list<string>
    match xs
      Cons('&', rest) ->
        val name = rest.take-while(fn(c) c != ';' && !c.is-ws && c != '&' && c != '<')
        match rest.drop(name.length)
          Cons(';', after) | !name.is-empty && name.head != Just('#') -> go(pretend-decreasing(after), Cons(name.string, acc))
          _ -> go(rest, acc)
      Cons(_, rest) -> go(rest, acc)
      Nil -> acc
  go(v.list, [])

// An entity must not refer to itself, directly or through other entities.
// (Entities that were checked already are remembered, so that a chain like
// "billion laughs" takes linear time.)
fun check-no-recursion( src : list<char>, at : list<char>, ents : list<(string, maybe<string>)> ) : exn ()
  fun visit( name : string, path : list<string>, done : list<string> ) : <exn,div> list<string>
    if done.any(fn(d) d == name) then done
    elif path.any(fn(p) p == name) then src.parse-error(at, "the entity &" ++ name ++ "; refers to itself")
    else match ents.lookup(fn(n) n == name)
      Just(Just(v)) -> Cons(name, v.entity-refs.foldl(done, fn(d, r) visit(r, Cons(name, path), d)))
      _ -> Cons(name, done)
  pretend-no-div { ignore(ents.foldl([], fn(d, (n, _)) visit(n, [], d))) }

// Replace character references (`&#65;`, `&#x41;`) but keep entity references.
fun expand-char-refs( src : list<char>, at : list<char>, s : string ) : exn string
  fun go( xs : list<char>, acc : list<char> ) : exn list<char>
    match xs
      Cons('&', Cons('#', rest)) ->
        val digits = rest.take-while(fn(c) c != ';')
        val code = match digits
          Cons('x', hs) -> hs.string.parse-int(hex = True)
          _ -> digits.string.parse-int
        match (code, rest.drop(digits.length))
          (Just(i), Cons(';', rest2)) -> go(pretend-decreasing(rest2), Cons(i.char, acc))
          _ -> src.parse-error(at, "invalid character reference in an entity value")
      Cons(c, rest) -> go(rest, Cons(c, acc))
      Nil -> acc.reverse
  go(s.list, []).string

fun is-name-start( c : char ) : bool
  c.is-alpha || c == '_' || c == ':' || c.int >= 0x80

fun is-name-char( c : char ) : bool
  c.is-name-start || c.is-digit || c == '-' || c == '.'

fun parse-name( src : list<char>, cs : list<char> ) : exn (string, list<char>)
  match cs
    Cons(c, _) | c.is-name-start ->
      val n = cs.take-while(is-name-char)
      (n.string, cs.drop(n.length))
    _ -> src.parse-error(cs, "expected a name")

// The first reference to a declared entity in `cs`: the text before it, its name, and the text after it.
fun find-entity-ref( cs : list<char>, ents : list<(string, maybe<string>)> ) : maybe<(list<char>, string, list<char>)>
  fun go( xs : list<char>, before : list<char> ) : maybe<(list<char>, string, list<char>)>
    match xs
      Nil -> Nothing
      Cons('&', rest) ->
        val name = rest.take-while(fn(c) c != ';' && !c.is-ws && c != '&' && c != '<')
        val nm = name.string
        match rest.drop(name.length)
          Cons(';', after) | ents.any(fn((n, _)) n == nm) -> Just((before.reverse, nm, after))
          _ -> go(rest, Cons('&', before))
      Cons(c, rest) -> go(rest, Cons(c, before))
  if ents.is-nil then Nothing else go(cs, [])

// Replace entity and character references. Declared entities (from the
// DOCTYPE) are replaced by their (recursively expanded) text.
fun unescape( src : list<char>, at : list<char>, s : string, ents : list<(string, maybe<string>)> = [] ) : exn string
  src.unescape-at(at, s, ents, 0)

fun unescape-at( src : list<char>, at : list<char>, s : string, ents : list<(string, maybe<string>)>, depth : int ) : exn string
  if depth > 32 then src.parse-error(at, "entity expansion limit exceeded")
  fun go( xs : list<char>, acc : list<char> ) : exn list<char>
    match xs
      Nil -> acc.reverse
      Cons('&', rest) ->
        val name = rest.take-while(fn(c) c != ';' && !c.is-ws && c != '&' && c != '<')
        val after = rest.drop(name.length)
        match after
          Cons(';', rest2) ->
            val c = match name.string
              "lt" -> '<'
              "gt" -> '>'
              "amp" -> '&'
              "quot" -> '"'
              "apos" -> '\''
              n | ents.any(fn((k, _)) k == n) ->
                match ents.lookup(fn(k) k == n)
                  Just(Just(v)) ->
                    val text = src.unescape-at(at, v, ents, pretend-decreasing(depth + 1))
                    if text.count > max-expansion then src.parse-error(at, "entity expansion limit exceeded")
                    if text.list.any(fn(x) x == '<') then src.parse-error(at, "the entity &" ++ n ++ "; contains '<', which is not allowed in an attribute value")
                    return go(pretend-decreasing(rest2), text.list.reverse ++ acc)
                  _ -> src.parse-error(at, "the external entity &" ++ n ++ "; is not loaded")
              n ->
                val code = if n.starts-with("#x").is-just then n.slice.drop(2).string.parse-int(hex = True)
                           elif n.starts-with("#").is-just then n.slice.drop(1).string.parse-int
                           else Nothing
                match code
                  Just(i) | (i == 0x9 || i == 0xA || i == 0xD || (i >= 0x20 && i < 0xD800) || (i > 0xDFFF && i <= 0x10FFFF)) && i != 0xFFFE && i != 0xFFFF -> i.char
                  _ -> src.parse-error(at, "unknown entity &" ++ n ++ ";")
            go(pretend-decreasing(rest2), Cons(c, acc))
          _ -> src.parse-error(at, "'&' must start an entity like &amp;")
      Cons(c, rest) -> go(rest, Cons(c, acc))
  go(s.list, []).string

fun parse-attrs( src : list<char>, cs : list<char>, acc : list<(string, string)>, ents : list<(string, maybe<string>)> ) : exn (list<(string, string)>, list<char>)
  val cs1 = cs.skip-ws
  match cs1
    Cons(c, _) | c.is-name-start ->
      if !cs.head.map(is-ws).default(False) then src.parse-error(cs, "expected a space before an attribute")
      val (name, rest) = src.parse-name(cs1)
      match rest.skip-ws
        Cons('=', rest1) -> match rest1.skip-ws
          Cons(q, rest2) | q == '"' || q == '\'' ->
            val (rawtext, rest3) = src.until(rest2, q.string, "attribute value")
            if rawtext.list.any(fn(x) x == '<') then src.parse-error(rest2, "'<' in an attribute value")
            if acc.any(fn((k, _)) k == name) then src.parse-error(cs1, "duplicate attribute " ++ name)
            // whitespace characters in attribute values are normalized to spaces
            val value = src.unescape(rest2, rawtext.list.map(fn(x) if x == '\n' || x == '\t' || x == '\r' then ' ' else x).string, ents)
            src.parse-attrs(pretend-decreasing(rest3), Cons((name, value), acc), ents)
          r -> src.parse-error(r, "expected a quoted attribute value")
        r -> src.parse-error(r, "expected '=' after the attribute name")
    _ -> (acc.reverse, cs1)

fun next-event( src : list<char>, st : pstate ) : <exn,div> maybe<(xml-event, pstate)>
  val cs = st.rest
  match cs
    Nil ->
      match st.open
        Cons(n, _) -> src.parse-error(cs, "unclosed element <" ++ n ++ ">")
        Nil -> if st.seen-root then Nothing else src.parse-error(cs, "no root element")
    Cons('<', rest) ->
      if rest.starts("!--") then
        val (text, rest1) = src.until(rest.drop(3), "-->", "comment")
        if text.contains("--") then src.parse-error(rest, "'--' inside a comment")
        Just((Comment-event(text), st(rest = rest1)))
      elif rest.starts("![CDATA[") then
        if st.open.is-nil then src.parse-error(cs, "CDATA outside the root element")
        val (text, rest1) = src.until(rest.drop(8), "]]>", "CDATA section")
        Just((CData-event(text), st(rest = rest1)))
      elif rest.starts("!DOCTYPE") then
        if st.seen-root || !st.open.is-nil then src.parse-error(cs, "DOCTYPE after the root element")
        val after = src.skip-doctype(rest.drop(8))
        val decl = rest.drop(8).take(rest.length - 8 - after.length)
        val ents = src.parse-entities(cs, decl, [])
        src.check-no-recursion(cs, ents)
        next-event(src, st(rest = after, entities = ents))
      elif rest.starts("?") then
        val (target, rest1) = src.parse-name(rest.drop(1))
        if target.to-lower == "xml" then src.parse-error(cs, "an XML declaration is only allowed at the start")
        val (data, rest2) = src.until(rest1, "?>", "processing instruction")
        Just((Instruction-event(target, data.trim-left), st(rest = rest2)))
      elif rest.starts("/") then
        val (name, rest1) = src.parse-name(rest.drop(1))
        match rest1.skip-ws
          Cons('>', rest2) -> match st.open
            Cons(n, outer) ->
              if n != name then src.parse-error(rest, "</" ++ name ++ "> does not match <" ++ n ++ ">")
              Just((End-element(name), st(rest = rest2, open = outer, seen-root = True)))
            Nil -> src.parse-error(rest, "unexpected </" ++ name ++ ">")
          r -> src.parse-error(r, "expected '>'")
      else
        if st.open.is-nil && st.seen-root then src.parse-error(cs, "a second root element")
        val (name, rest1) = src.parse-name(rest)
        val (attrs, rest2) = src.parse-attrs(rest1, [], st.entities)
        match rest2
          Cons('/', Cons('>', rest3)) ->
            // an empty element: a start event now, and its end event next
            Just((Start-element(name, attrs), st(rest = ['<', '/'] ++ name.list ++ ['>'] ++ rest3, open = Cons(name, st.open))))
          Cons('>', rest3) -> Just((Start-element(name, attrs), st(rest = rest3, open = Cons(name, st.open))))
          r -> src.parse-error(r, "expected '>' or '/>'")
    _ ->
      val rawtext = cs.take-while(fn(c) c != '<')
      val rest = cs.drop(rawtext.length)
      if st.open.is-nil then
        if rawtext.all(is-ws) then next-event(src, st(rest = rest))
        else src.parse-error(cs, "text outside the root element")
      else
        if rawtext.string.contains("]]>") then src.parse-error(cs, "']]>' in text")
        match rawtext.find-entity-ref(st.entities)
          Nothing -> Just((Text-event(src.unescape(cs, rawtext.string, st.entities)), st(rest = rest)))
          Just((before, ename, after)) ->
            // a declared entity: its replacement text is parsed in place of the reference
            val value = match st.entities.lookup(fn(n) n == ename)
              Just(Just(v)) -> v
              _ -> src.parse-error(cs, "the external entity &" ++ ename ++ "; is not loaded")
            val total = st.expanded + value.count
            if total > max-expansion then src.parse-error(cs, "entity expansion limit exceeded")
            val st1 = st(rest = value.list ++ after ++ rest, expanded = total)
            if before.is-empty then next-event(src, pretend-decreasing(st1))
            else Just((Text-event(src.unescape(cs, before.string, st.entities)), st1))

// ----------------------------------------------------------------------------
// The DOCTYPE
// ----------------------------------------------------------------------------

// A document type declaration `<!DOCTYPE name PUBLIC "pub" "sys" [ subset ]>`.
pub struct doctype
  name : string              // the name of the root element
  public-id : string         // `""` if there is none
  system-id : string         // the URI of the external DTD; `""` if there is none
  internal-subset : string   // the declarations between `[` and `]`

// The DOCTYPE of a document, if it has one (see `std/data/xml/dtd` for validation).
pub fun parse-doctype( s : string ) : exn maybe<doctype>
  val src = s.list
  fun find( cs : list<char> ) : exn maybe<doctype>
    val c1 = cs.skip-ws
    if c1.starts("<!--") then find(pretend-decreasing(c1.drop(4).skip-past("-->")))
    elif c1.starts("<?") then find(pretend-decreasing(c1.drop(2).skip-past("?>")))
    elif c1.starts("<!DOCTYPE") then
      val body = c1.drop(9)
      val after = src.skip-doctype(body)
      val decl = body.take(body.length - after.length - 1)   // without the final '>'
      val (name, rest) = src.parse-name(decl.skip-ws)
      val r1 = rest.skip-ws
      val (pubid, sysid, r2) =
        if r1.starts("SYSTEM") then
          val (sys, r) = src.literal(r1.drop(6).skip-ws)
          ("", sys, r)
        elif r1.starts("PUBLIC") then
          val (pubtext, r) = src.literal(r1.drop(6).skip-ws)
          val (sys, r') = src.literal(r.skip-ws)
          (pubtext, sys, r')
        else ("", "", r1)
      val subset = match r2.skip-ws
        Cons('[', inner) -> match inner.reverse.skip-ws
          Cons(']', before) -> before.reverse.string
          _ -> src.parse-error(cs, "expected ']' at the end of the internal subset")
        Nil -> ""
        _ -> src.parse-error(cs, "unexpected text in the DOCTYPE")
      Just(Doctype(name, pubid, sysid, subset))
    else Nothing
  find(src.skip-prolog)

fun literal( src : list<char>, cs : list<char> ) : exn (string, list<char>)
  match cs
    Cons(q, rest) | q == '"' || q == '\'' -> src.until(rest, q.string, "literal")
    _ -> src.parse-error(cs, "expected a quoted literal")

// ----------------------------------------------------------------------------
// Building the tree
// ----------------------------------------------------------------------------

// Parse a document and return its root element (comments and processing
// instructions outside the root are dropped). Raises an exception with the
// line and column for a document that is not well formed. With `namespaces`,
// names are expanded to `{uri}local` (see `expand-namespaces`).
pub fun parse-xml( s : string, namespaces : bool = False ) : exn xml
  val evs = pretend-no-div { xml-events(s).list }
  val root = match build-nodes(evs, [])
    (roots, _) -> match roots.filter(fn(x) x.is-named("*"))
      [r] -> r
      _ -> throw("xml: no root element")
  if namespaces then root.expand-namespaces else root

// ----------------------------------------------------------------------------
// Namespaces
// ----------------------------------------------------------------------------

val xml-namespace = "http://www.w3.org/XML/1998/namespace"
val xmlns-namespace = "http://www.w3.org/2000/xmlns/"

// Resolve namespace prefixes: element and attribute names become `{uri}local`
// using the `xmlns` and `xmlns:prefix` declarations in scope (attributes
// without a prefix have no namespace, and names in no namespace stay plain).
// The declarations themselves are kept, as `{http://www.w3.org/2000/xmlns/}prefix`
// (and `xmlns` for the default). Raises an exception for an undeclared prefix.
pub fun expand-namespaces( x : xml ) : exn xml
  x.expand-in([("xml", xml-namespace)])

fun expand-in( x : xml, scope : list<(string, string)> ) : exn xml
  match x
    Element(n, attrs, cs) ->
      val decls = attrs.filter-map fn((k, v))
        if k == "xmlns" then Just(("", v))
        elif k.starts-with("xmlns:").is-just then Just((k.slice.drop(6).string, v))
        else Nothing
      val scope1 = decls ++ scope
      val attrs1 = attrs.map fn((k, v))
        if k == "xmlns" then (k, v)
        elif k.starts-with("xmlns:").is-just then ("{" ++ xmlns-namespace ++ "}" ++ k.slice.drop(6).string, v)
        else (k.expand-name(scope1, False), v)
      match attrs1.map(fst).find-dup
        Just(d) -> throw("xml: duplicate attribute " ++ d ++ " after resolving namespaces")
        Nothing -> ()
      Element(n.expand-name(scope1, True), attrs1, cs.map(fn(c) pretend-decreasing(c).expand-in(scope1)))
    _ -> x

fun find-dup( xs : list<string> ) : maybe<string>
  match xs
    Cons(x, rest) -> if rest.any(fn(y) y == x) then Just(x) else rest.find-dup
    Nil -> Nothing

fun expand-name( n : string, scope : list<(string, string)>, is-element : bool ) : exn string
  match n.find(":")
    Just(sl) ->
      val pre = sl.before.string
      match scope.lookup(fn(p) p == pre)
        Just(uri) -> "{" ++ uri ++ "}" ++ sl.after.string
        Nothing -> throw("xml: undeclared namespace prefix " ++ pre.show ++ " in " ++ n.show)
    Nothing ->
      if !is-element then n
      else match scope.lookup(fn(p) p == "")
        Just(uri) | !uri.is-empty -> "{" ++ uri ++ "}" ++ n
        _ -> n

// The namespace of an expanded name `{uri}local` (`""` for a plain name).
pub fun namespace-uri( name : string ) : string
  if name.starts-with("{").is-nothing then ""
  else match name.find("}")
    Just(sl) -> sl.before.string.slice.drop(1).string
    Nothing -> ""

// The local part of a name: `local` for `{uri}local` and for `prefix:local`.
pub fun local-name( name : string ) : string
  val s1 = match name.find("}")
    Just(sl) | name.starts-with("{").is-just -> sl.after.string
    _ -> name
  match s1.find(":")
    Just(sl) -> sl.after.string
    Nothing -> s1

// The child elements with namespace `uri` and local name `local`.
pub fun elements-ns( x : xml, uri : string, local : string ) : list<xml>
  x.elements.filter(fn(c) c.tag.namespace-uri == uri && c.tag.local-name == local)

// Parse a document, returning `Nothing` if it is not well formed.
pub fun try-parse-xml( s : string ) : maybe<xml>
  catch(fn(_) Nothing, { Just(parse-xml(s)) })

// Build the nodes up to the end of the current element; returns them and the remaining events.
fun build-nodes( evs : list<xml-event>, acc : list<xml> ) : (list<xml>, list<xml-event>)
  match evs
    Nil -> (acc.reverse, [])
    Cons(ev, rest) -> match ev
      End-element(_) -> (acc.reverse, rest)
      Start-element(n, attrs) ->
        val (cs, rest1) = build-nodes(rest, [])
        build-nodes(pretend-decreasing(rest1), Cons(Element(n, attrs, cs.merge-text), acc))
      Text-event(t) -> build-nodes(rest, Cons(Text(t), acc))
      CData-event(t) -> build-nodes(rest, Cons(CData(t), acc))
      Comment-event(t) -> build-nodes(rest, Cons(Comment(t), acc))
      Instruction-event(t, d) -> build-nodes(rest, Cons(Instruction(t, d), acc))

// Merge adjacent text nodes.
fun merge-text( xs : list<xml> ) : list<xml>
  match xs
    Cons(Text(a), Cons(Text(b), rest)) -> pretend-decreasing(Cons(Text(a ++ b), rest)).merge-text
    Cons(x, rest) -> Cons(x, rest.merge-text)
    Nil -> Nil
