import std/data/json
import std/num/float64

struct person(name : string, age : int, email : maybe<string>)

fun person/json( p : person ) : json
  json-object([("name", p.name.json), ("age", p.age.json), ("email", p.email.json)])

fun person-from-json( j : json ) : maybe<person>
  match (j.at("name").as-string, j.at("age").as-int)
    (Just(n), Just(a)) -> Just(Person(n, a, j.at("email").as-string))
    _ -> Nothing

fun main()
  val src = r#"{"name": "koka", "tags": ["fun", "effects"], "version": 3, "pi": 3.14159,
                "nested": {"ok": true, "none": null, "big": 123456789012345678901234567890},
                "esc": "line\nbreak \"quoted\" \u00e9 \ud83d\ude00 tab\t"}"#
  val j = parse-json(src)
  println(j.at("name").as-string)
  println(j.at("tags").as-array.map(fn(xs) xs.length))
  println((j.at("version").as-int, j.at("pi").as-float, j.path(["nested","big"]).as-int))
  println((j.path(["nested","ok"]).as-bool, j.path(["nested","none"]).is-null, j.at("missing").is-null))
  println(j.at("esc").as-string)
  println(j.keys)
  println(j.stringify)
  println(parse-json(j.stringify) == j)
  println(parse-json(j.pretty) == j)
  println(json-object([("a", 1.json), ("b", [1,2].json), ("c", json-object([]))]).pretty)
  println(json-object([("b", 2.json), ("a", 1.json)]) == json-object([("a", 1.json), ("b", 2.json)]))
  println((1.json == 1.0.json, "x".json == 1.json))
  // round trip through user types
  val people = [Person("ann", 30, Just("ann@example.com")), Person("bob", 25, Nothing)]
  val pj = people.json
  println(pj.stringify)
  println(pj.as-array.default([]).map(person-from-json).map(fn(mp) mp.map(fn(p) p.name)))
  println(j.set("version", 4.json).remove("tags").remove("esc").remove("nested").stringify)
  println([(1,"a"),(2,"b")].json.stringify)
  println(["a\u0001b".json.stringify, (0.0/0.0).json.stringify, 1.5e300.json.stringify, (-0.25).json.stringify])
  // syntax errors
  val bad = ["", "{", "[1,]", "{\"a\" 1}", "01", "1.", "\"abc", "tru", "[1] x", "\"\\x\"", "{\"a\":1,}"]
  bad.foreach fn(s)
    println(catch(fn(e) e.message, { parse-json(s).stringify }))
  println(try-parse-json("[1, 2.5e3, -0, true]").map(stringify))
  // larger document
  val arr = json-array(list(1,5000).map(fn(i) json-object([("id", i.json), ("v", (i*2).show.json)])))
  val txt = arr.stringify
  println((txt.count, parse-json(txt) == arr))
