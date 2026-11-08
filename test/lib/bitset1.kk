// std/data/bitset
import std/data/bitset
import std/core/seq

fun main()
  val primes = bitset([2, 3, 5, 7, 11, 13, 13, -4])
  val odds = range-bitset(0, 15).filter(is-odd)
  println(primes.intersection(odds).show ++ " " ++ (primes - odds).show ++ " " ++ (primes + odds).show ++ " " ++ primes.sym-difference(odds).show)
  println((primes.count, primes.member(7), primes.member(8), primes.member(-1)))
  println((bitset/empty.count, bitset/empty.is-empty))
  println((primes.minimum, primes.maximum, bitset/empty.maximum, primes.next-member(6), primes.next-member(14)))
  // across word boundaries
  val wide = bitset([0, 63, 64, 127, 128, 1000, 100000])
  println((wide.list, wide.count, wide.maximum, wide.next-member(129)))
  println((range-bitset(60, 70).list, range-bitset(5, 4).is-empty, range-bitset(0, 127).count, range-bitset(-5, 2).list))
  println((wide.remove(100000).maximum, wide.remove(100000).remove(1000) == bitset([0, 63, 64, 127, 128]), wide.insert(5).count, wide.insert(-1) == wide))
  println((bitset([1, 2]).is-subset(bitset([1, 2, 3])), bitset([1, 4]).is-subset(bitset([1, 2, 3])), bitset([1]).is-disjoint(bitset([2]))))
  println((bitset([3, 1]).complement(6).list, (wide - wide).is-empty, (wide - wide) == bitset/empty, wide.seq.take(3).list))
  println(wide.foldl(0, fn(a, x) a + x))
  // a sieve over a large range
  val n = 100000
  val sieve = list(2, 316).foldl(range-bitset(2, n)) fn(s, p)
    if s.member(p) then s - bitset(list(2, n / p).map(fn(k) k * p)) else s
  println((sieve.count, sieve.maximum))
