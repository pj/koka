// A match nested in a branch of another match (here the check for a yielding
// effect operation) must keep its `break` out of the outer labeled block: the
// JS backend left it out, so the next branch of the outer match ran as well.
effect later
  ctl later( x : int ) : int

fun handle-later( action : () -> <later,console|e> a ) : <console|e> a
  with ctl later(x)
    resume(x * 10)
  action()

fun send( tag : string, a : string, b : int ) : console ()
  println(tag ++ " " ++ a ++ " " ++ b.show)

fun serve( m : maybe<int>, flag : bool, hs : string, status : string ) : <later,console|e> bool
  val keep = flag
  val first = status ++ "!"
  val kept = match m
    Just(x) | flag && x > 100 ->
      send("big", first, x)
      keep
    Just(x) ->
      val body = later(x)
      send("later", first ++ hs, body)
      keep
    Nothing ->
      send("none", first, 0)
      keep
  if kept then send("kept", hs, 1)
  kept

fun main()
  handle-later
    println(serve(Just(5), True, "H", "S"))
    println(serve(Just(500), True, "H", "S"))
    println(serve(Nothing, False, "H", "S"))
