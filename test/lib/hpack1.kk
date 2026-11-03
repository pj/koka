// HPACK (RFC 7541): the examples of appendix C, Huffman coding, and encoding round trips
import std/net/hpack
import std/text/encoding

// groups of examples decoded in sequence with one decoder (of the given table size):
// (name, hex encoding, expected headers, expected table size after decoding)
val examples : list<(int, list<(string, string, list<(string, string)>, int)>)> = [
  (4096, [
    ("C.2.1", "400a637573746f6d2d6b65790d637573746f6d2d686561646572", [("custom-key", "custom-header")], 0) ]),
  (4096, [
    ("C.2.2", "040c2f73616d706c652f70617468", [(":path", "/sample/path")], 0) ]),
  (4096, [
    ("C.2.3", "100870617373776f726406736563726574", [("password", "secret")], 0) ]),
  (4096, [
    ("C.2.4", "82", [(":method", "GET")], 0) ]),
  (4096, [
    ("C.3.1", "828684410f7777772e6578616d706c652e636f6d", [(":method", "GET"), (":scheme", "http"), (":path", "/"), (":authority", "www.example.com")], 0),
    ("C.3.2", "828684be58086e6f2d6361636865", [(":method", "GET"), (":scheme", "http"), (":path", "/"), (":authority", "www.example.com"), ("cache-control", "no-cache")], 110),
    ("C.3.3", "828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565", [(":method", "GET"), (":scheme", "https"), (":path", "/index.html"), (":authority", "www.example.com"), ("custom-key", "custom-value")], 164) ]),
  (4096, [
    ("C.4.1", "828684418cf1e3c2e5f23a6ba0ab90f4ff", [(":method", "GET"), (":scheme", "http"), (":path", "/"), (":authority", "www.example.com")], 0),
    ("C.4.2", "828684be5886a8eb10649cbf", [(":method", "GET"), (":scheme", "http"), (":path", "/"), (":authority", "www.example.com"), ("cache-control", "no-cache")], 110),
    ("C.4.3", "828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf", [(":method", "GET"), (":scheme", "https"), (":path", "/index.html"), (":authority", "www.example.com"), ("custom-key", "custom-value")], 164) ]),
  (256, [
    ("C.5.1", "4803333032580770726976617465611d4d6f6e2c203231204f637420323031332032303a31333a323120474d546e1768747470733a2f2f7777772e6578616d706c652e636f6d", [(":status", "302"), ("cache-control", "private"), ("date", "Mon, 21 Oct 2013 20:13:21 GMT"), ("location", "https://www.example.com")], 222),
    ("C.5.2", "4803333037c1c0bf", [(":status", "307"), ("cache-control", "private"), ("date", "Mon, 21 Oct 2013 20:13:21 GMT"), ("location", "https://www.example.com")], 222),
    ("C.5.3", "88c1611d4d6f6e2c203231204f637420323031332032303a31333a323220474d54c05a04677a69707738666f6f3d4153444a4b48514b425a584f5157454f50495541585157454f49553b206d61782d6167653d333630303b2076657273696f6e3d31", [(":status", "200"), ("cache-control", "private"), ("date", "Mon, 21 Oct 2013 20:13:22 GMT"), ("location", "https://www.example.com"), ("content-encoding", "gzip"), ("set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1")], 215) ]),
  (256, [
    ("C.6.1", "488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3", [(":status", "302"), ("cache-control", "private"), ("date", "Mon, 21 Oct 2013 20:13:21 GMT"), ("location", "https://www.example.com")], 222),
    ("C.6.2", "4883640effc1c0bf", [(":status", "307"), ("cache-control", "private"), ("date", "Mon, 21 Oct 2013 20:13:21 GMT"), ("location", "https://www.example.com")], 222),
    ("C.6.3", "88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007", [(":status", "200"), ("cache-control", "private"), ("date", "Mon, 21 Oct 2013 20:13:22 GMT"), ("location", "https://www.example.com"), ("content-encoding", "gzip"), ("set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1")], 215) ])
]

fun hex-bytes( s : string ) : bytes
  match hex-decode(s)
    Just(b) -> b
    Nothing -> bytes/empty

fun main()
  examples.foreach fn((size, exs))
    exs.foldl(hpack-decoder(size)) fn(dec, (name, hex, expected, expected-size))
      val (headers, dec') = catch(fn(e) { println(name ++ ": " ++ e.message); ([], dec) }, { dec.decode(hex-bytes(hex)) })
      println(name ++ ": " ++ (if headers == expected then "ok" else "MISMATCH " ++ headers.show) ++
              (if expected-size == 0 || dec'.table-size == expected-size then "" else ", table size " ++ dec'.table-size.show))
      dec'
    ()
  // Huffman coding (RFC 7541 C.4.1)
  println(huffman-encode("www.example.com".bytes).hex-encode)
  println(huffman-decode(hex-bytes("f1e3c2e5f23a6ba0ab90f4ff")).string)
  // all byte values round trip
  val all = list(0, 255).vector.bytes
  println(huffman-decode(huffman-encode(all)).list == all.list)
  // invalid input is rejected
  println(catch(fn(e) "rejected", { huffman-decode(hex-bytes("ff")).string }))   // padding longer than 7 bits
  println(catch(fn(e) "rejected", { hpack-decoder().decode(hex-bytes("be")).fst.show }))   // index beyond the tables
  println(catch(fn(e) "rejected", { hpack-decoder().decode(hex-bytes("418c")).fst.show }))   // truncated
  // encoding round trips, with and without Huffman coding
  val hs = [(":method", "GET"), (":scheme", "https"), (":path", "/search?q=koka"), (":authority", "example.com"),
            ("accept", "*/*"), ("user-agent", "koka-http"), ("x-custom", "value with spaces and ünïcödé")]
  println(hpack-decoder().decode(hpack-encode(hs)).fst == hs)
  println(hpack-decoder().decode(hpack-encode(hs, huffman = False)).fst == hs)
  println(hpack-encode([(":method", "GET")]).hex-encode)   // fully indexed
