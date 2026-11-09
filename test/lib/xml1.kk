// std/data/xml
import std/data/xml
import std/core/seq

fun check( name : string, src : string ) : console ()
  match try({ parse-xml(src) })
    Ok(x) -> println(name ++ ": " ++ x.stringify)
    Error(e) -> println(name ++ ": error: " ++ e.message)

fun first-events( s : string, n : int ) : <exn,div> list<string>
  xml-events(s).take(n).map(fn(ev) match ev { Start-element(t, _) -> "<" ++ t ++ ">"; End-element(t) -> "</" ++ t ++ ">"; Text-event(t) -> t; _ -> "?" }).list

fun main()
  val doc = parse-xml(r#"<feed><entry id="1"><title>Koka &amp; effects</title></entry><entry id="2"/></feed>"#)
  doc.elements("entry").foreach fn(e)
    println(e.attr("id").default("") ++ ": " ++ e.child("title").map(text-content).default("-"))
  println(doc.stringify)

  val src = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE note [ <!ELEMENT note (to,from)> <!ATTLIST note id CDATA "x"> ]>
<!-- a note -->
<note id='n1' lang="en">
  <to>Tove</to>
  <from>Jani &#x263A; &#65;&lt;&gt;&quot;&apos;</from>
  <body><![CDATA[Don't <forget> & remember]]> me</body>
  <?render fast?>
  <empty/>
  <nested><a><b>deep</b></a></nested>
</note>
<!-- trailing -->"#
  val note = parse-xml(src)
  println((note.tag, note.attr("id"), note.attr("lang"), note.attr("missing")))
  println(note.child("from").map(text-content))
  println(note.child("body").map(text-content))
  println(note.find-all("b").map(text-content) ++ note.elements.map(tag))
  println(note.text-content.count)
  println(note.stringify(indent = 2))
  // round trip
  println(parse-xml(note.stringify).stringify == note.stringify)
  // escaping in output
  println(Element("p", [("title", "a \"quoted\" <value> & more")], [Text("1 < 2 & 3 > 2")]).stringify)

  // the pull parser is lazy: the start of a broken document can be read
  val broken = "<log><line>one</line><line>two</line><line>three</oops>"
  println(first-events(broken, 5).join(" "))
  println(try({ first-events(broken, 100).length }).is-error)
  println(first-events("<a x='1'>t<!--c--><b/></a>", 100).length)

  // errors
  check("mismatched", "<a><b></a></b>")
  check("unclosed", "<a><b></b>")
  check("two roots", "<a/><b/>")
  check("duplicate attribute", "<a x='1' x='2'/>")
  check("unknown entity", "<a>&nbsp;</a>")
  check("bare ampersand", "<a>fish & chips</a>")
  check("text outside", "hello <a/>")
  check("empty", "  ")
  check("lt in attribute", "<a x='<'/>")
  check("unquoted attribute", "<a x=1/>")
  check("bad name", "<1a/>")
  check("comment dashes", "<a><!-- a -- b --></a>")
  check("multi-line error", "<a>\n  <b>\n  </c>\n</a>")
  check("attribute whitespace", "<a x='one\ntwo'/>")
  check("bom and decl", "﻿<?xml version='1.0'?><a/>")
