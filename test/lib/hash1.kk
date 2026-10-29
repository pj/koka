import std/data/hash

struct point(x : int, y : int)

fun point/hash( p : point ) : int
  hash-combine(p.x.hash, p.y.hash)

fun main()
  // deterministic values, identical on C and JS
  println([0.hash, 1.hash, (-1).hash, 0x7FFF_FFFF.hash, 0x8000_0000.hash, (-0x8000_0001).hash])
  println(123456789012345678901234567890.hash)
  println(["".hash, "a".hash, "hello".hash, "héllo wörld".hash, "😀 emoji".hash])
  println('x'.hash == 'x'.int.hash)
  println((True.hash != False.hash, ().hash == ().hash))
  println([1,2,3].hash == [1,2,3].hash)
  println([1,2,3].hash != [3,2,1].hash)
  println([[1],[2,3]].hash != [[1,2],[3]].hash)
  println((1,"a").hash == (1,"a").hash)
  println((Just(1).hash != (Nothing : maybe<int>).hash, Just(0).hash != (Nothing : maybe<int>).hash))
  println((0.0.hash == (-0.0).hash, 1.5.hash != 2.5.hash))
  println(Point(1,2).hash != Point(2,1).hash)
  println([Point(1,2), Point(3,4)].hash == [Point(1,2), Point(3,4)].hash)
  // distribution sanity: hashes of 0..9999 should be (nearly) all distinct and in range
  val hs = list(0,9999).map(hash)
  println((hs.all(fn(h) h >= 0 && h < 0x1_0000_0000), hs.sort.dedup.length))
  val ss = list(0,9999).map(fn(i) ("key" ++ i.show).hash)
  println(ss.sort.dedup.length)
