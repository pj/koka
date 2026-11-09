// External templates with ten or more arguments: `#10` is the tenth argument
// (it used to be read as `#1` followed by `0`).
extern pick( a1 : int, a2 : int, a3 : int, a4 : int, a5 : int, a6 : int, a7 : int, a8 : int, a9 : int, a10 : int, a11 : int ) : int
  c  inline "kk_integer_add(#10,kk_integer_add(#11,#1,kk_context()),kk_context())"
  js inline "$std_core_types._int_add(#10,$std_core_types._int_add(#11,#1))"

fun main()
  println(pick(1, 2, 3, 4, 5, 6, 7, 8, 9, 1000, 20000))
