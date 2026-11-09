// closures created in a loop (a tail-recursive function, or one in trmc form)
// must see the values of that iteration, not of a later one
fun callbacks( xs : list<int>, i : int ) : list<() -> int>
  match xs
    Cons(x, rest) ->
      val f = fn() x * 10 + i
      Cons(f, callbacks(rest, i + 1))
    Nil -> Nil

fun collect( xs : list<int>, acc : list<() -> int> ) : list<() -> int>
  match xs
    Cons(x, rest) ->
      val f = fn() x
      collect(rest, Cons(f, acc))
    Nil -> acc

fun main()
  println(callbacks([1, 2, 3], 0).map(fn(f) f()))
  println(collect([1, 2, 3], []).map(fn(f) f()))
