/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Efficient string building.

   Repeatedly appending to a string with `++` copies the string each time.
   A `:builder` collects the pieces and joins them once at the end, in
   _O(n)_ total.

   ```
   val b = builder().add("hello").add-char(',').add(" world")
   b.string    // "hello, world"
   ```

   Or use the `build` function with the `emit` effect:

   ```
   build
     for(1,3) fn(i) emit(i.show)
   // "123"
   ```
*/
module std/text/builder

// A string builder.
pub value struct builder
  parts : list<string>   // in reverse order
  len : int              // number of parts

// Create an empty string builder.
pub fun builder() : builder
  Builder([], 0)

// Append a string.
pub fun add( b : builder, s : string ) : builder
  Builder(Cons(s, b.parts), b.len + 1)

// Append a character.
pub fun add-char( b : builder, c : char ) : builder
  b.add(c.string)

// Append a string followed by a newline.
pub fun add-line( b : builder, s : string = "" ) : builder
  b.add(s).add("\n")

// Append a list of strings separated by `sep`.
pub fun add-all( b : builder, xs : list<string>, sep : string = "" ) : builder
  b.add(xs.join(sep))

// Is the builder empty?
pub fun is-empty( b : builder ) : bool
  b.parts.all(fn(s) s.is-empty)

// The string built so far.
pub fun builder/string( b : builder ) : string
  b.parts.reverse.join

pub fun show( b : builder ) : string
  b.string.show

// The `emit` effect appends a string to the string being built by `build`.
pub effect emit
  fun emit( s : string ) : ()

// Emit a string followed by a newline.
pub fun emit-line( s : string = "" ) : emit ()
  emit(s)
  emit("\n")

// Run `action` and return the concatenation of everything it emits.
pub fun build( action : () -> <emit|e> () ) : e string
  var parts := Nil
  with fun emit(s) parts := Cons(s, parts)
  action()
  parts.reverse.join
