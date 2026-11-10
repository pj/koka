// integers made from an int64 compare equal to the same value computed by
// arithmetic (with SOFA arithmetic and 32-bit bigint digits, as with clang-cl on
// Windows, these used to get different representations near 2^30)
import std/num/int64

fun check( v : int ) : bool
  val n = v.int64.int                   // from an int64
  val s = (v - 12345) + 12345           // by addition
  val m = (v / 2) * 2 + (v % 2)         // by multiplication
  n == s && s == n && n == m && m == n && n <= s && n >= s && !(n < s) && !(n > s) && n.show == v.show

fun main()
  val bounds = [0x1FFFFFFF, 0x20000000, 1000000000, 0x3FFFFFFF, 0x40000000, 0x79DCDD47, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x100000000]
  val vs = bounds.flatmap(fn(b) [b - 1, b, b + 1, ~b - 1, ~b, ~b + 1])
  println(vs.length)
  println(vs.filter(fn(v) !check(v)))
