// std/data/toml: TOML 1.0 parsing and writing
import std/data/toml
import std/data/json
import std/num/float64

val example = r#"
# This is a TOML document

title = "TOML Example"

[owner]
name = "Tom Preston-Werner"
dob = 1979-05-27T07:32:00-08:00

[database]
enabled = true
ports = [ 8000, 8001, 8002 ]
data = [ ["delta", "phi"], [3.14] ]
temp_targets = { cpu = 79.5, case = 72.0 }

[servers]

[servers.alpha]
ip = "10.0.0.1"
role = "frontend"

[servers.beta]
ip = "10.0.0.2"
role = "backend"
"#

fun check( name : string, src : string ) : <console> ()
  match try({ parse-toml(src) })
    Ok(t) -> println(name ++ ": " ++ t.json.stringify)
    Error(e) -> println(name ++ ": error: " ++ e.message)

fun main()
  val doc = parse-toml(example)
  println(doc.json.stringify)
  println(doc.path(["servers", "beta", "role"]).as-string)
  println(doc.at("database").at("ports").as-array.map(fn(xs) xs.length))
  println(doc.at("owner").at("dob").as-datetime-kind.map(show).default("") ++ " " ++ doc.at("owner").at("dob").as-datetime.default(""))
  println(doc.keys)

  // strings
  check("basic", r#"s = "tab\there \"quoted\" \u00E9 \U0001F600""#)
  check("literal", r#"s = 'C:\Users\nodejs\templates'"#)
  check("multi-line", "s = \"\"\"\nRoses are red\nViolets are blue\"\"\"")
  check("line-ending backslash", "s = \"\"\"\\\n    The quick brown \\\n\n    fox.\"\"\"")
  check("quotes in multi-line", r#"s = """Here are two quotation marks: "". Simple enough."""
t = """"This," she said, "is just a pointless statement.""""
u = '''That's still pointless'''"#)
  check("multi-line literal", "s = '''\nThe first newline is\ntrimmed in raw strings.\n   All other whitespace\n   is preserved.\n'''")

  // numbers
  check("integers", "a = +99\nb = 42\nc = 0\nd = -17\ne = 1_000\nf = 5_349_221\ng = 0xDEAD_beef\nh = 0o755\ni = 0b1101_0110\nj = 9223372036854775807")
  check("floats", "a = +1.0\nb = 3.1415\nc = -0.01\nd = 5e+22\ne = 1e06\nf = -2E-2\ng = 6.626e-34\nh = 224_617.445_991")
  match try({ parse-toml("a = inf\nb = -inf\nc = nan\nd = +nan") })
    Ok(t) -> println(t.keys.map(fn(k) t.at(k).show).join(" "))
    Error(e) -> println(e.message)

  // dates and times
  check("dates", "a = 1979-05-27T07:32:00Z\nb = 1979-05-27T00:32:00.999999-07:00\nc = 1979-05-27 07:32:00Z\nd = 1979-05-27T07:32:00\ne = 1979-05-27\nf = 07:32:00\ng = 00:32:00.999999\nh = 1979-05-27t07:32:00z")
  println(parse-toml("a = 1979-05-27 07:32:00Z\nb = 07:32:00\nc = 2000-02-29").keys.map(fn(k) parse-toml("a = 1979-05-27 07:32:00Z\nb = 07:32:00\nc = 2000-02-29").at(k).as-datetime-kind.map(show).default("")))

  // keys and tables
  check("keys", r#"bare_key-1 = 1
"quoted key" = 2
'literal key' = 3
site."google.com" = true
a . b . c = 4
3.14159 = "pi""#)
  check("dotted and headers", "fruit.apple.color = 'red'\nfruit.apple.taste.sweet = true\n[fruit.apple.texture]\nsmooth = true")
  check("implicit then explicit", "[x.y.z.w]\na = 1\n[x]\nb = 2")
  check("array of tables", r#"[[products]]
name = "Hammer"
sku = 738594937

[[products]]  # empty table within the array

[[products]]
name = "Nail"
sku = 284758393
color = "gray""#)
  check("nested arrays of tables", "[[fruits]]\nname = 'apple'\n[fruits.physical]\ncolor = 'red'\n[[fruits.varieties]]\nname = 'red delicious'\n[[fruits.varieties]]\nname = 'granny smith'\n[[fruits]]\nname = 'banana'\n[[fruits.varieties]]\nname = 'plantain'")
  check("inline tables", "name = { first = \"Tom\", last = \"Preston-Werner\" }\npoint = { x = 1, y = 2 }\nanimal = { type.name = \"pug\" }\nempty = {}")
  check("arrays", "a = [ 1, 2, 3, ]\nb = [\n  \"x\", # comment\n  'y',\n]\nc = [ [ 1, 2 ], [\"a\", 'b'] ]\nd = []\ne = [ { x = 1 }, { x = 2 } ]")
  check("crlf and comments", "a = 1 # one\r\n# full line\r\n[t] # table\r\nb = 2\r\n")

  // errors
  check("duplicate key", "a = 1\na = 2")
  check("table twice", "[fruit]\napple = 'red'\n[fruit]\norange = 'orange'")
  check("dotted then header", "[fruit]\napple.color = 'red'\n[fruit.apple]\ntexture = 'smooth'")
  check("extend inline", "a = { b = 1 }\n[a.c]\nd = 2")
  check("static array", "fruits = []\n[[fruits]]\nx = 1")
  check("leading zero", "a = 012")
  check("double underscore", "a = 1__000")
  check("bad date", "a = 2001-02-29")
  check("bad escape", r#"a = "\x41""#)
  check("newline in string", "a = \"one\ntwo\"")
  check("no value", "a = ")
  check("two on a line", "a = 1 b = 2")
  check("unterminated", "a = [1, 2")
  check("signed hex", "a = +0x10")

  // writing: the output parses back to the same document
  val out = doc.stringify
  println(out)
  println(parse-toml(out) == doc)
  val tricky = TTable([("a b", TString("line\n\"q\"\t\u0001")), ("t", TTable([("x", TFloat(posinf-value())), ("y", TFloat(1.0))])),
                       ("arr", TArray([TTable([("k", TInt(1))]), TTable([])])), ("nested", TTable([("deep", TTable([("v", TBool(False))]))]))])
  val tout = tricky.stringify
  println(tout)
  println(parse-toml(tout) == tricky)

fun posinf-value() : exn float64
  parse-toml("x = inf").at("x").as-float.default(0.0)
