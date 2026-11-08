// std/text/unicode against the Unicode conformance tests (GraphemeBreakTest,
// WordBreakTest and a sample of NormalizationTest from the UCD), plus examples
import std/text/unicode
import std/os/path
import std/os/file
import std/os/fs

fun data( name : string ) : io string
  val local = ("unicode-data/" ++ name).path
  read-text-file(if path-exists(local) then local else ("test/lib/unicode-data/" ++ name).path)

fun hex-string( s : string ) : string
  s.split(" ").filter(fn(x) !x.is-empty).map(fn(x) x.parse-int(hex = True).default(0).char.string).join

// The segments of a break test line like "÷ 0020 × 0308 ÷ 0020 ÷".
fun expected-segments( line : string ) : (string, list<string>)
  val tokens = line.split("#").head.default("").split(" ").flatmap(fn(t) t.split("\t")).filter(fn(t) !t.is-empty)
  fun go( ts : list<string>, cur : string, acc : list<string> ) : list<string>
    match ts
      Nil -> (if cur.is-empty then acc else Cons(cur, acc)).reverse
      Cons("÷", rest) -> go(rest, "", if cur.is-empty then acc else Cons(cur, acc))
      Cons("×", rest) -> go(rest, cur, acc)
      Cons(h, rest) -> go(rest, cur ++ hex-string(h), acc)
  val segs = go(tokens, "", [])
  (segs.join, segs)

fun break-test( name : string, file : string, split : string -> list<string> ) : io ()
  val lines = data(file).lines.filter(fn(l) !l.starts-with("#").is-just && !l.trim.is-empty)
  val failures = lines.filter fn(l)
    val (s, segs) = expected-segments(l)
    split(s) != segs
  println(name ++ ": " ++ (lines.length - failures.length).show ++ "/" ++ lines.length.show ++ " pass")
  failures.take(5).foreach(fn(l) println("  FAIL " ++ l))

fun show-cps( s : string ) : string
  s.list.map(fn(c) c.int.show-hex(4, pre = "")).join(" ")

fun normalization-test() : io ()
  val lines = data("NormalizationTest-sample.txt").lines.filter(fn(l) !l.starts-with("#").is-just && !l.starts-with("@").is-just && !l.trim.is-empty)
  var failed := 0
  var shown := 0
  lines.foreach fn(l)
    match l.split(";").map(hex-string)
      Cons(c1, Cons(c2, Cons(c3, Cons(c4, Cons(c5, _))))) ->
        val checks = [
          [c1, c2, c3].all(fn(x) x.normalize(NFC) == c2), [c4, c5].all(fn(x) x.normalize(NFC) == c4),
          [c1, c2, c3].all(fn(x) x.normalize(NFD) == c3), [c4, c5].all(fn(x) x.normalize(NFD) == c5),
          [c1, c2, c3, c4, c5].all(fn(x) x.normalize(NFKC) == c4), [c1, c2, c3, c4, c5].all(fn(x) x.normalize(NFKD) == c5) ]
        if !checks.all(id) then
          failed := failed + 1
          if shown < 5 then
            shown := shown + 1
            println("  FAIL " ++ l ++ " -> NFC " ++ c1.normalize(NFC).show-cps ++ ", NFD " ++ c1.normalize(NFD).show-cps)
      _ -> ()
  println("normalization: " ++ (lines.length - failed).show ++ "/" ++ lines.length.show ++ " pass")

fun main()
  println(unicode-version)
  break-test("graphemes", "GraphemeBreakTest.txt", graphemes)
  break-test("words", "WordBreakTest.txt", word-segments)
  normalization-test()

  // examples
  println("é👍🏽🇳🇿👨‍👩‍👧 ok".graphemes)
  println(["éx".grapheme-count, "".grapheme-count, "🇳🇿🇦🇺".grapheme-count, "\r\n".grapheme-count])
  println("Hello, world! It's 3.14 o'clock — naïve café".words)
  println("can't stop, won't stop".word-segments)
  println("日本語のテキスト".words)
  println(["abc", "日本", "👍", "👍🏽", "🇳🇿", "é", "​", "❤️", "♥", ""].map(width))
  println(["A".width, "́".width, "\t".width])
  println(["Straße", "ǅ", "ΣΊΣΥΦΟΣ", "ﬁ", "İ"].map(fold-case))
  println(("STRASSE".equals-ignore-case("straße"), "Koka".equals-ignore-case("KOKA"), "a".equals-ignore-case("b")))
  println(["é".normalize.count, "é".normalize(NFD).count, "ﬁ".normalize(NFKC).count, "한".normalize(NFD).count, "한".normalize.count])
