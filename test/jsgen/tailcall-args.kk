// A self tail call becomes a loop that assigns the parameters; an argument that
// is another parameter must be read before the parameters are overwritten.
fun find( xs : list<int>, target : int, i : int, found : int ) : int
  match xs
    Cons(x, rest) ->
      if x == target then find(rest, target, i + 1, i)
      else find(rest, target, i + 1, found)
    Nil -> found

fun swap-loop( a : int, b : int, n : int ) : div (int, int)
  if n <= 0 then (a, b) else swap-loop(b, a, n - 1)

fun rotate( a : int, b : int, c : int, n : int ) : div (int, int, int)
  if n <= 0 then (a, b, c) else rotate(c, a, b, n - 1)

fun main()
  println(find([10, 20, 30], 20, 1, 0))
  println(swap-loop(1, 2, 1))
  println(swap-loop(1, 2, 2))
  println(rotate(1, 2, 3, 1))
