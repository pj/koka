// A long chain of `||` over `&&` clauses: case-of-case used to copy the rest
// of the chain into both branches of every clause, doubling the generated
// code per clause (10 clauses took 20 minutes to compile). This one has 16.
fun word-like( a : int, b : int, c : int ) : bool
  (a == 1 && b == 1) || (a == 2 && b == 1) || (a == 1 && b == 2) || (a == 3 && c == 3)
  || (a == 4 && b == 4) || (b == 5 && c == 5) || (a == 6 && c == 6) || (a == 7 && b == 7)
  || (a == 8 && b == 8) || (a == 9 && c == 9) || (b == 10 && c == 10) || (a == 11 && b == 11)
  || ((a == 12 || a == 13) && b == 12) || (a == 14 && (b == 14 || c == 14)) || (a == 15 && b == 15 && c == 15)
  || (a == 16 && b == 16)

fun main()
  println(list(0, 17).filter(fn(i) word-like(i, i, i)))
  println(list(0, 17).filter(fn(i) word-like(i, 0, i)))
