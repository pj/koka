// std/data/xml: entities declared in the DOCTYPE
import std/data/xml

fun check( name : string, src : string ) : console ()
  match try({ parse-xml(src) })
    Ok(x) -> println(name ++ ": " ++ x.stringify)
    Error(e) -> println(name ++ ": error: " ++ e.message)

fun main()
  val doc = r#"<?xml version="1.0"?>
<!DOCTYPE note [
  <!-- a comment with <!ENTITY fake "no"> inside -->
  <!ENTITY company "Koka &amp; Co">
  <!ENTITY sig "<b>Best</b>, &company;">
  <!ENTITY copy "&#169;">
  <!ENTITY % param "ignored">
  <!ENTITY company "the second declaration does not count">
]>
<note from="&company;">&sig; &copy; 2026</note>"#
  check("entities", doc)
  val x = parse-xml(doc)
  println((x.attr("from"), x.find-all("b").map(text-content), x.text-content))
  check("undeclared", "<!DOCTYPE a [<!ENTITY e 'x'>]><a>&f;</a>")
  check("external", "<!DOCTYPE a [<!ENTITY ext SYSTEM 'file:///etc/passwd'>]><a>&ext;</a>")
  check("markup in an attribute", "<!DOCTYPE a [<!ENTITY m '<b/>'>]><a x='&m;'/>")
  check("recursive", "<!DOCTYPE a [<!ENTITY r '&r;&r;'>]><a>&r;</a>")
  check("recursive in an attribute", "<!DOCTYPE a [<!ENTITY r '&r;'>]><a x='&r;'/>")
  check("billion laughs", r#"<!DOCTYPE lolz [
 <!ENTITY lol "lol">
 <!ENTITY lol1 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
 <!ENTITY lol2 "&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;">
 <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
 <!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">
 <!ENTITY lol5 "&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;">
 <!ENTITY lol6 "&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;">
 <!ENTITY lol7 "&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;">
]><lolz>&lol7;</lolz>"#)
