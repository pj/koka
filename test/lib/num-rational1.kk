// std/num/rational and std/num/complex
import std/num/rational
import std/num/complex
import std/num/float64

fun main()
  val third = rational(1, 3)
  println((third + rational(1, 6)).show)
  println((third * 3.rational).show)
  println([rational(6, -8).show, rational(0, 5).show, rational(5, 0).show, rational(-10, 4).show].join(" "))
  println((rational(1, 2) - rational(3, 4)).show ++ " " ++ (rational(3, 4) / rational(-9, 2)).show ++ " " ++ (rational(2, 3) ^ -3).show)
  println([rational(7, 2), rational(-7, 2), rational(5, 2), rational(-5, 2), rational(1, 3)].map(fn(r) (r.floor, r.ceiling, r.truncate, r.round).show).join(" "))
  println((rational(1, 3) < rational(1, 2), rational(2, 4) == rational(1, 2), cmp(rational(-1, 2), rational(-1, 3)) == Lt).show)
  println(rational(22, 7).show-decimal(5) ++ " " ++ rational(-1, 3).show-decimal(3) ++ " " ++ rational(2, 3).show-decimal(0) ++ " " ++ rational(-1, 1000).show-decimal(2))
  println(["3/4", " -6 / 8 ", "12", "-1.25", "0.1", ".5", "1/0", "x"].map(fn(s) parse-rational(s).map(show).default("-")).join(" "))
  println((0.1.rational.show, 0.5.rational.show, (-2.75).rational.show))
  println((rational(1, 3).float64.show-fixed(15), rational(-22, 7).float64.show-fixed(15), (rational(1, 3) ^ 200).float64 > 0.0, rational(1, 3).float64 == 1.0 / 3.0))
  // exact arithmetic: the harmonic number H(30)
  println(list(1, 30).map(fn(k) rational(1, k)).sum.show)
  println((rational(1, 3).numerator, rational(-4, 6).denominator, rational(-4, 6).sign, rational(7, 3).fraction.show))

  val z = complex(3.0, 4.0)
  println((z.abs, (z * z.conj).show, (z / z).show, (z - z).show))
  println((z * i).show ++ " " ++ (i * i).show ++ " " ++ (z ^ 2).show ++ " " ++ (z ^ -1).show(4))
  println(exp(complex(0.0, pi)).show(3) ++ " " ++ complex(-4.0).sqrt.show ++ " " ++ complex(0.0, 2.0).sqrt.show(6) ++ " " ++ complex(-1.0, -0.0).sqrt.show)
  println(ln(complex(-1.0)).show(5) ++ " " ++ pow(i, i).show(6) ++ " " ++ pow(complex(2.0), complex(10.0)).show(3))
  println((complex(1.0, 1.0).arg.show-fixed(12), polar(2.0, pi / 2.0).show(3), complex(1e300, 1e300) / complex(1e300, 1e300) == one))
  println((sin(complex(1.0, 2.0)).show(6), cos(complex(1.0, 2.0)).show(6)))
