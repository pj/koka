/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Unit and property testing.

   ```
   import std/test

   fun main()
     run-tests
       group("list")
         test("sort")
           expect-eq([3,1,2].sort, [1,2,3])
         test("reverse twice")
           check-property("reverse . reverse == id", gen-list(gen-int(0,100))) fn(xs)
             xs.reverse.reverse == xs
       test("failing")
         expect(1 + 1 == 3, "arithmetic")
   ```

   `run-tests` prints a line per failing test (and per passing test when
   `verbose` is `True`), a summary, and exits with code 1 if any test failed.
   Failure messages include the source location of the failing expectation.
*/
module std/test

import std/num/random
import std/os/io

// The outcome of a single test.
pub type outcome
  Pass
  Fail( message : string )

// The effect used by tests to report their outcome.
pub effect testing
  fun report( name : string, result : outcome ) : ()

// Define a test: runs `body` and reports `Pass`, or `Fail` with the message of
// the first exception (for example a failed `expect`).
pub fun test( name : string, body : () -> <exn,testing|e> () ) : <testing|e> ()
  report(name, run-body(body))

fun run-body( body : () -> <exn|e> () ) : e outcome
  catch(fn(ex) Fail(ex.message), { body(); Pass })

// Group tests under a common name prefix.
pub fun group( name : string, body : () -> <testing,testing|e> () ) : <testing|e> ()
  with fun report(n, o) report(name ++ " / " ++ n, o)
  body()

// The result of running a set of tests.
pub struct summary
  passed : int
  failed : list<(string, string)>   // (test name, failure message)

// Run tests and collect the results without printing.
pub fun collect-tests( body : () -> <testing|e> () ) : e summary
  var passed := 0
  var failed := []
  with fun report(name, outcome)
    match outcome
      Pass -> passed := passed + 1
      Fail(msg) -> failed := Cons((name, msg), failed)
  body()
  Summary(passed, failed.reverse)

// Run tests, print failures and a summary, and exit with code 1 if any test failed.
pub fun run-tests( body : () -> <testing,io|e> (), verbose : bool = False ) : <io|e> ()
  var passed := 0
  var failed := 0
  with fun report(name, outcome)
    match outcome
      Pass ->
        passed := passed + 1
        if verbose then println("ok    " ++ name)
      Fail(msg) ->
        failed := failed + 1
        println("FAIL  " ++ name)
        println("      " ++ msg)
  body()
  val total = passed + failed
  println((if failed == 0 then "all " ++ total.show ++ " tests passed"
           else failed.show ++ " of " ++ total.show ++ " tests failed"))
  if failed > 0 then exit(1)

// ----------------------------------------------------------------------------
// Expectations
// ----------------------------------------------------------------------------

// Fail the current test with a message.
pub fun fail( message : string, ?kk-file-line : string ) : exn a
  throw(kk-file-line ++ ": " ++ message)

// Expect a condition to hold.
pub fun expect( condition : bool, message : string = "expectation failed", ?kk-file-line : string ) : exn ()
  if !condition then throw(kk-file-line ++ ": " ++ message)

// Expect `actual` to equal `expected`.
pub fun expect-eq( actual : a, expected : a, ?(==) : (a,a) -> <exn|e> bool, ?show : a -> <exn|e> string, ?kk-file-line : string ) : <exn|e> ()
  if !(actual == expected) then
    throw(kk-file-line ++ ": expected " ++ expected.show ++ ", but got " ++ actual.show)

// Expect `actual` to differ from `unexpected`.
pub fun expect-ne( actual : a, unexpected : a, ?(==) : (a,a) -> <exn|e> bool, ?show : a -> <exn|e> string, ?kk-file-line : string ) : <exn|e> ()
  if actual == unexpected then
    throw(kk-file-line ++ ": expected a value different from " ++ unexpected.show)

// Expect `action` to raise an exception.
pub fun expect-throws( action : () -> <exn,exn|e> a, ?kk-file-line : string ) : <exn|e> ()
  val threw = catch(fn(_) True, { action(); False })
  if !threw then throw(kk-file-line ++ ": expected an exception")

// ----------------------------------------------------------------------------
// Property testing
// ----------------------------------------------------------------------------

// A generator of random test values.
pub alias gen<a> = () -> random a

pub fun gen-int( lo : int = -1000, hi : int = 1000 ) : gen<int>
  fn() lo + (random-int() % (hi - lo + 1)).abs

pub fun gen-bool() : gen<bool>
  fn() random-bool()

pub fun gen-char( lo : char = ' ', hi : char = '~' ) : gen<char>
  fn() (lo.int + (random-int() % (hi.int - lo.int + 1)).abs).char

pub fun gen-list( g : gen<a>, max-len : int = 20 ) : gen<list<a>>
  fn() list(1, (random-int() % (max-len + 1)).abs).map(fn(_) g())

pub fun gen-string( max-len : int = 20, g : gen<char> = gen-char() ) : gen<string>
  fn() gen-list(g, max-len)().string

pub fun gen-pair( ga : gen<a>, gb : gen<b> ) : gen<(a,b)>
  fn() (ga(), gb())

pub fun gen-one-of( xs : list<a>, fallback : a ) : gen<a>
  fn() xs.drop((random-int() % (xs.length.max(1))).abs).head.default(fallback)

// Check that `prop` holds for `count` random values from `g` (with a fixed
// `seed` so failures are reproducible). Fails with the first counterexample.
pub fun check-property( name : string, g : gen<a>, prop : a -> bool, count : int = 100, seed : int = 42,
                        ?show : a -> string, ?kk-file-line : string ) : exn ()
  val counterexample = pseudo-random(seed) fn()
    list(1, count).foldl(Nothing) fn(found, _)
      match found
        Just -> found
        Nothing ->
          val x = g()
          if prop(x) then Nothing else Just(x)
  match counterexample
    Just(x) -> throw(kk-file-line ++ ": property " ++ name.show ++ " failed for " ++ x.show)
    Nothing -> ()
