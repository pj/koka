// std/text/pretty
import std/text/pretty

fun call( f : string, args : list<doc> ) : doc
  text(f) ++ tupled(args)

type json
  JNum( n : int )
  JStr( s : string )
  JArr( xs : list<json> )
  JObj( fs : list<(string, json)> )

fun jdoc( j : json ) : div doc
  match j
    JNum(n) -> n.doc
    JStr(s) -> text(s).dquotes
    JArr(xs) -> block(xs.map(jdoc).punctuate(text(",")), text("["), text("]"))
    JObj(fs) -> block(fs.map(fn((k, v)) text(k).dquotes ++ text(":") <+> v.jdoc).punctuate(text(",")))

fun show-widths( d : doc, widths : list<int> ) : console ()
  widths.foreach fn(w)
    println("-- width " ++ w.show)
    println(d.pretty(w))

fun main()
  val d = call("frobnicate", [text("alpha"), text("beta"), call("inner", [text("gamma"), text("delta")])])
  d.show-widths([80, 30, 20])

  // statements in a block
  val prog = text("while") <+> text("(x > 0)") <+> block([text("x = x - 1;"), text("print(x);")])
  prog.show-widths([60, 20])

  // nested JSON
  val j = JObj([("name", JStr("koka")), ("tags", JArr([JStr("fun"), JStr("effects"), JStr("fbip")])), ("version", JNum(3)),
                ("deps", JObj([("std", JStr("*"))]))])
  j.jdoc.show-widths([100, 40, 10])

  // fill-sep wraps like a paragraph
  val words = "the quick brown fox jumps over the lazy dog and keeps on running".split(" ").map(text)
  println(fill-sep(words).pretty(20))
  println("--")
  // hang and align
  println((text("let x =") <+> align(vsep([text("first"), text("second")]))).pretty)
  println((text("item:") <+> fill-sep(words).hang(2)).pretty(24))
  println(indent(vsep([text("a"), text("b")]), 4).pretty)
  // fill aligns columns
  val rows = [("name", "string"), ("age", "int"), ("verylongname", "bool")]
  println(vcat(rows.map(fn((n, t)) text(n).fill(6) <+> text(":") <+> text(t))).pretty)
  println("--")
  println(vcat(rows.map(fn((n, t)) text(n).fill-break(6) <+> text(t))).pretty)
  println("--")
  // hard lines and text with newlines
  println(group(text("a") <-> text("b") ++ hardline ++ text("c")).pretty)
  println(text("one\ntwo").nest(2).pretty ++ "|")
  println((list-doc([]) <+> tupled([1.doc]) <+> semi-braces([text("x"), text("y")]) <+> sep([text("p"), text("q")])).pretty)
  println(cat([text("a"), text("b")]).pretty ++ " " ++ hsep([text("a"), empty, text("b")]).pretty ++ " " ++ hcat([text("a"), text("b")]).pretty)
  // a long list breaks with leading separators
  println(list-doc(list(1, 30).map(doc)).pretty(40))
