// std/io/stream: byte streams, and file handles in std/os/fs
import std/io/stream
import std/os/fs

fun chunk-sizes( s : byte-stream<e> ) : <div|e> list<int>
  s.map(fn(b) b.length).list

fun main()
  // splitting and decoding, with chunks that split lines and characters
  val text = "hello\nwörld\r\n\nlast"
  for(1, 4) fn(n)
    val s = text.stream(n)
    println(n.show ++ ": " ++ s.lines.list.show ++ " " ++ s.decode-utf8.join.show)
  println("a\nb\n".stream.lines.list)
  println("".stream.lines.list.show)
  println("\n".stream.lines.list)
  println("x,y,,z".stream(2).split-bytes(','.int).map(string).list)
  println("€uro".stream(1).decode-utf8.list)
  println(["ab", "cd"].seq.unlines.read-text.show)
  println(["ab", "cd"].seq.encode-utf8.read-text)

  // rechunking and byte ranges
  val digits = "0123456789".stream(3)
  println(digits.chunk-sizes)
  println(digits.rechunk(4).map(string).list)
  println(digits.rechunk(1).byte-count)
  println("0123456789".stream(10).rechunk(3).map(string).list)
  println(digits.take-bytes(5).read-text ++ " " ++ digits.drop-bytes(5).read-text)
  println(digits.take-bytes(0).read-text.show ++ " " ++ digits.drop-bytes(20).read-text.show)

  // reading incrementally
  val msg = "GET / HTTP/1.1\r\nHost: x\r\n\r\nBODY12345tail".stream(4)
  match msg.read-line
    Nothing -> println("no request line")
    Just((request-line, rest1)) ->
      match rest1.read-line
        Nothing -> println("no header")
        Just((header, rest2)) ->
          match rest2.read-line
            Nothing -> println("no blank line")
            Just((blank, rest3)) ->
              val (body, rest4) = rest3.read-bytes(9)
              println([request-line, header, blank, body.string, rest4.read-text].show)
  match "no newline".stream(3).read-line
    Just((l, rest)) -> println(l ++ " / " ++ rest.read-text.show)
    Nothing -> println("nothing")
  println("".stream.read-line.map(fst).show)
  match "key=value".stream(2).read-until('='.int)
    Just((k, rest)) -> println(k.string ++ " -> " ++ rest.read-text)
    Nothing -> println("no =")
  println("abc".stream.read-until('='.int).map(fn((b, _)) b.string).show)
  println(try({ "aaaaaaaa=".stream(2).read-until('='.int, max-len = 4).map(fn((b, _)) b.string) }).is-error)
  println("abc".stream.read-bytes(10).fst.string)

  // a stream from a reader is consumed as it is read
  val chunks = ref(["one", "two", "three"])
  val reader = from-reader fn()
    match !chunks
      Cons(c, cs) -> { chunks := cs; c.bytes }
      Nil -> bytes/empty
  println(reader.take(1).map(string).list ++ reader.map(string).list)

  // files
  with-temp-dir fn(dir)
    val f = dir / "data.txt"
    with-file(f, Write) fn(h)
      h.write-text("line 1\n")
      h.write("line 2\n".bytes)
    with-file(f, Append) fn(h)
      h.write-text("line 3")
    with-file(f, Read) fn(h)
      println(h.stream(5).lines.list)
    with-file(f, Read) fn(h)
      // a stream reads ahead (here up to 8 bytes for the first line), then read continues after that
      println(h.stream(4).lines.take(1).list)
      println(h.read(100).string.show)
      println(h.read(100).length)

    // a large file, copied as a stream and read line by line
    val big = dir / "big.txt"
    write-stream(big, range(1, 100000).map(fn(i) i.show).unlines.rechunk(65536))
    println(file-size(big))
    val copy = dir / "sub" / "copy.txt"
    with-file(big, Read) fn(h)
      write-stream(copy, h.stream)
    append-stream(copy, "100001\n".stream)
    with-file(copy, Read) fn(h)
      println(h.stream.lines.foldl(0, fn(acc, l) acc + l.parse-int.default(0)))
    with-file(copy, Read) fn(h)
      println(h.stream(1000).lines.drop(99998).list)

    // closing twice is fine; reading after closing is an error
    val h = open-file(f)
    println(h.read(4).string)
    h.close
    h.close
    println(try({ h.read }).is-error)
    println(try({ open-file(dir / "missing.txt") }).is-error)
