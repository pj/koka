// std/data/xml/dtd: parsing DTDs and validating documents
import std/data/xml
import std/data/xml/dtd

val subset = r#"
  <!-- a small catalog -->
  <!ENTITY % id-attr "id ID #REQUIRED">
  <!ELEMENT catalog (title, (book | magazine)*, note?)>
  <!ELEMENT title (#PCDATA)>
  <!ELEMENT book (author+, price)>
  <!ATTLIST book %id-attr; lang (en|de|fr) "en" status CDATA #FIXED "ok" related IDREFS #IMPLIED>
  <!ELEMENT magazine EMPTY>
  <!ATTLIST magazine issue NMTOKEN #REQUIRED>
  <!ELEMENT author (#PCDATA | em)*>
  <!ELEMENT em (#PCDATA)>
  <!ELEMENT price (#PCDATA)>
  <!ELEMENT note ANY>
  <![IGNORE[ <!ELEMENT title EMPTY> ]]>
  <![INCLUDE[ <!ATTLIST catalog version CDATA "1.0"> ]]>
"#

fun doc( body : string ) : string
  "<?xml version=\"1.0\"?>\n<!DOCTYPE catalog [" ++ subset ++ "]>\n" ++ body

fun errors( body : string ) : exn list<string>
  val s = doc(body)
  validate(parse-xml(s), parse-dtd(subset), "catalog")

fun main()
  val dt = parse-doctype(doc("<catalog/>")).map(fn(d) (d.name, d.system-id, d.internal-subset.count > 100))
  println(dt)
  println(parse-doctype("<?xml version=\"1.0\"?><!-- c --><!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\"><html/>").map(fn(d) (d.name, d.public-id, d.system-id)))
  val d = parse-dtd(subset)
  println(d.elements.map(fn((n, spec)) n ++ ": " ++ (match spec { Children(m) -> m.show; Mixed(ns) -> "mixed " ++ ns.show; Empty-content -> "EMPTY"; Any-content -> "ANY" })))
  println(d.attributes.map(fn(a) a.element ++ "@" ++ a.name))
  val good = "<catalog version='2'><title>Books</title><book id='b1' lang='de' related='b2'><author>Ann <em>A.</em></author><price>3</price></book>" ++
             "<magazine issue='42'/><book id='b2'><author>Bob</author><author>Cy</author><price>5</price></book><note><title>any</title> text</note></catalog>"
  println(errors(good))
  // defaults are added
  val v = parse-valid-xml(doc(good))
  println(v.elements("book").map(fn(b) (b.attr("lang"), b.attr("status"))))
  println(v.attr("version"))
  // invalid documents
  [ "<catalog><book id='x'><author>A</author><price>1</price></book></catalog>",        // missing title
    "<catalog><title>T</title><book id='x'><price>1</price></book></catalog>",           // no author
    "<catalog><title>T</title><dvd/></catalog>",                                          // undeclared element
    "<catalog><title>T</title><book><author>A</author><price>1</price></book></catalog>", // missing id
    "<catalog><title>T</title><book id='a' lang='es'><author>A</author><price>1</price></book></catalog>",
    "<catalog><title>T</title><book id='a' status='bad'><author>A</author><price>1</price></book></catalog>",
    "<catalog><title>T</title><book id='a'><author>A</author><price>1</price></book><book id='a'><author>B</author><price>2</price></book></catalog>",
    "<catalog><title>T</title><book id='a' related='a zz'><author>A</author><price>1</price></book></catalog>",
    "<catalog><title>T</title><magazine issue='4 2'>x</magazine></catalog>",
    "<catalog><title>T<em>x</em></title>stray text</catalog>",
    "<catalog><title>T</title><book id='a' color='red'><author>A</author><price>1</price></book></catalog>"
  ].foreach fn(b) println(errors(b))
  // the root must match the DOCTYPE
  println(validate(parse-xml("<title>x</title>"), d, "catalog"))
  // parse-valid-xml raises for an invalid document, and needs a DOCTYPE
  println(try-parse("<catalog><title>T</title><dvd/></catalog>".doc))
  println(try-parse("<catalog/>"))
  // an external DTD given as text
  val ext = "<!ELEMENT greeting (#PCDATA)>"
  println(parse-valid-xml("<!DOCTYPE greeting SYSTEM \"hello.dtd\"><greeting>hi</greeting>", ext).text-content)
  // DTD syntax errors
  println(try-dtd("<!ELEMENT a (b,c|d)>"))
  println(try-dtd("<!ELEMENT a %undeclared;>"))
  println(try-dtd("<!ATTLIST a b BOGUS #IMPLIED>"))

fun try-parse( s : string ) : string
  match try(fn() parse-valid-xml(s))
    Ok(x) -> "ok " ++ x.tag
    Error(e) -> e.message

fun try-dtd( s : string ) : string
  match try(fn() parse-dtd(s))
    Ok(_) -> "ok"
    Error(e) -> e.message
