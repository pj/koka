/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* SQLite databases.

   ```
   import std/db/sqlite

   fun main()
     with-database(":memory:") fn(db)
       db.exec("create table person(id integer primary key, name text not null, age int)")
       db.execute("insert into person(name, age) values (?, ?)", ["ada".sql, 36.sql])
       db.execute("insert into person(name, age) values (?, ?)", ["bob".sql, SqlNull])
       db.query("select name, age from person order by name").foreach fn(r)
         println(r.text("name").default("") ++ ": " ++ r.int("age").map(show).default("unknown"))
   ```

   Values are passed as parameters (`?` in the SQL, bound in order), never
   pasted into the SQL text, so they need no quoting. `transaction` runs a
   function in a transaction that is rolled back if the function raises an
   exception.

   On the C backend this links the system `sqlite3` library. On the
   JavaScript backend it uses Node's `node:sqlite` (Node 22.5 or later).
*/
module std/db/sqlite

import std/core/undiv
import std/num/float64

extern import
  c  { syslib="sqlite3" }

extern import
  c  file "sqlite-inline.c"
  js file "sqlite-inline.js"

// A value in a database.
pub type sql-value
  SqlNull
  SqlInt( i : int )
  SqlFloat( f : float64 )
  SqlText( s : string )
  SqlBlob( b : bytes )

pub fun int/sql( i : int ) : sql-value
  SqlInt(i)

pub fun float64/sql( f : float64 ) : sql-value
  SqlFloat(f)

pub fun string/sql( s : string ) : sql-value
  SqlText(s)

pub fun bytes/sql( b : bytes ) : sql-value
  SqlBlob(b)

// Booleans are stored as 1 and 0.
pub fun bool/sql( b : bool ) : sql-value
  SqlInt(if b then 1 else 0)

// `Nothing` is stored as `NULL`.
pub fun maybe/sql( m : maybe<a>, ?sql : a -> sql-value ) : sql-value
  match m
    Just(x) -> x.sql
    Nothing -> SqlNull

pub fun sql-value/show( v : sql-value ) : string
  match v
    SqlNull -> "NULL"
    SqlInt(i) -> i.show
    SqlFloat(f) -> f.show
    SqlText(s) -> s.show
    SqlBlob(b) -> b.show

pub fun sql-value/(==)( a : sql-value, b : sql-value ) : bool
  match (a, b)
    (SqlNull, SqlNull) -> True
    (SqlInt(x), SqlInt(y)) -> x == y
    (SqlFloat(x), SqlFloat(y)) -> x == y
    (SqlText(x), SqlText(y)) -> x == y
    (SqlBlob(x), SqlBlob(y)) -> x.list == y.list
    _ -> False

// A result row: the column names and their values.
pub struct row
  names : list<string>
  values : list<sql-value>

// The value of column `name` (`SqlNull` if there is no such column).
pub fun row/at( r : row, name : string ) : sql-value
  match zip(r.names, r.values).lookup(fn(n) n == name)
    Just(v) -> v
    Nothing -> SqlNull

// The value of the column at position `i` (from 0).
pub fun row/value( r : row, i : int ) : sql-value
  r.values.drop(i).head.default(SqlNull)

// The integer in column `name` (`Nothing` for NULL or a non-integer).
pub fun row/int( r : row, name : string ) : maybe<int>
  match r.at(name)
    SqlInt(i) -> Just(i)
    _ -> Nothing

// The number in column `name` (integers are converted).
pub fun row/float( r : row, name : string ) : maybe<float64>
  match r.at(name)
    SqlFloat(f) -> Just(f)
    SqlInt(i) -> Just(i.float64)
    _ -> Nothing

// The text in column `name`.
pub fun row/text( r : row, name : string ) : maybe<string>
  match r.at(name)
    SqlText(s) -> Just(s)
    _ -> Nothing

// The blob in column `name`.
pub fun row/blob( r : row, name : string ) : maybe<bytes>
  match r.at(name)
    SqlBlob(b) -> Just(b)
    _ -> Nothing

// Is column `name` NULL (or missing)?
pub fun row/is-null( r : row, name : string ) : bool
  match r.at(name)
    SqlNull -> True
    _ -> False

pub fun row/show( r : row ) : string
  "{" ++ zip(r.names, r.values).map(fn((n, v)) n ++ ": " ++ v.show).join(", ") ++ "}"

// ----------------------------------------------------------------------------
// Databases
// ----------------------------------------------------------------------------

// An open database.
abstract struct database( hnd : any, path : string )

// The version of the SQLite library.
pub fun sqlite-version() : fsys string
  prim-version()

fun fail( db : database, what : string ) : <fsys,exn> a
  val msg = prim-errmsg(db.hnd)
  throw("sqlite: " ++ what ++ (if msg.is-empty then "" else ": " ++ msg))

// Open (or create) a database file; `":memory:"` is a new in-memory database.
pub fun open-database( path : string = ":memory:" ) : <fsys,exn> database
  val db = Database(prim-open(path), path)
  if !prim-errmsg(db.hnd).is-empty then
    val msg = prim-errmsg(db.hnd)
    prim-close(db.hnd)
    throw("sqlite: unable to open " ++ path.show ++ ": " ++ msg)
  db

// Open a database, run `action` with it, and close it afterwards.
pub fun with-database( path : string, action : database -> <fsys,exn|e> a ) : <fsys,exn|e> a
  val db = open-database(path)
  with finally { prim-close(db.hnd) }
  action(db)

// Close the database (closing it again does nothing).
pub fun database/close( db : database ) : fsys ()
  prim-close(db.hnd)

// Run SQL statements that take no parameters, such as a schema.
pub fun exec( db : database, sql : string ) : <fsys,exn> ()
  val msg = prim-exec(db.hnd, sql)
  if !msg.is-empty then throw("sqlite: " ++ msg)

// Run one statement with `params` bound to its `?` placeholders, calling
// `on-row` for every result row. Returns the number of changed rows.
fun run( db : database, sql : string, params : list<sql-value>, on-row : row -> <fsys,exn|e> () ) : <fsys,exn|e> int
  val (st, _) = prim-prepare(db.hnd, sql)
  if prim-is-null-stmt(st) then db.fail("cannot prepare " ++ sql.show)
  with finally { prim-finalize(st) }
  val expected = prim-param-count(st)
  if expected >= 0 && expected != params.length then
    throw("sqlite: the statement takes " ++ expected.show ++ " parameters, but " ++ params.length.show ++ " were given")
  params.foreach-indexed fn(i, v)
    val code = match v
      SqlNull -> prim-bind-null(st, i + 1)
      SqlInt(n) -> prim-bind-int(st, i + 1, n)
      SqlFloat(f) -> prim-bind-float(st, i + 1, f)
      SqlText(s) -> prim-bind-text(st, i + 1, s)
      SqlBlob(b) -> prim-bind-blob(st, i + 1, b)
    if code != 0 then db.fail("cannot bind parameter " ++ (i + 1).show)
  fun steps( names : maybe<list<string>>, n : int )
    val r = prim-step(st)
    if r == 100 then
      val ns = match names
        Just(ns) -> ns
        Nothing -> list(0, prim-column-count(st) - 1).map(fn(i) prim-column-name(st, i))
      val vs = list(0, ns.length - 1).map fn(i)
        match prim-column-type(st, i)
          1 -> SqlInt(prim-column-int(st, i))
          2 -> SqlFloat(prim-column-float(st, i))
          3 -> SqlText(prim-column-text(st, i))
          4 -> SqlBlob(prim-column-blob(st, i))
          _ -> SqlNull
      on-row(Row(ns, vs))
      steps(Just(ns), pretend-decreasing(n + 1))
    elif r != 101 then db.fail("cannot run " ++ sql.show)
  steps(Nothing, 0)
  prim-changes(db.hnd)

// Run a statement (like `insert`, `update` or `delete`) with `params` for
// its `?` placeholders, and return the number of changed rows.
pub fun execute( db : database, sql : string, params : list<sql-value> = [] ) : <fsys,exn> int
  db.run(sql, params, fn(_) ())

// Run a query with `params` for its `?` placeholders, and return all rows.
pub fun query( db : database, sql : string, params : list<sql-value> = [] ) : <fsys,exn> list<row>
  var rows := []
  db.run(sql, params, fn(r) rows := Cons(r, rows))
  rows.reverse

// Run a query and call `f` on each row as it is read (without collecting them).
pub fun query-each( db : database, sql : string, params : list<sql-value>, f : row -> <fsys,exn|e> () ) : <fsys,exn|e> ()
  db.run(sql, params, f)
  ()

// The first row of a query, if any.
pub fun query-one( db : database, sql : string, params : list<sql-value> = [] ) : <fsys,exn> maybe<row>
  db.query(sql, params).head

// The first column of the first row of a query, if any (like `select count(*) ...`).
pub fun query-value( db : database, sql : string, params : list<sql-value> = [] ) : <fsys,exn> maybe<sql-value>
  db.query-one(sql, params).map(fn(r) r.value(0))

// The row id of the last inserted row.
pub fun last-insert-rowid( db : database ) : fsys int
  prim-last-rowid(db.hnd)

// Run `action` in a transaction: it is committed if `action` returns, and
// rolled back if it raises an exception (which is raised again).
pub fun transaction( db : database, action : () -> <fsys,exn|e> a ) : <fsys,exn|e> a
  db.exec("begin")
  var committed := False
  with finally { if !committed then ignore(prim-exec(db.hnd, "rollback")) }
  val x = action()
  db.exec("commit")
  committed := True
  x

// ----------------------------------------------------------------------------
// Primitives
// ----------------------------------------------------------------------------

extern prim-version() : fsys string
  c  "kk_sqlite_version"
  js "_sqlite_version"

extern prim-open( path : string ) : fsys any
  c  "kk_sqlite_open"
  js "_sqlite_open"

extern prim-errmsg( db : any ) : fsys string
  c  "kk_sqlite_errmsg"
  js "_sqlite_errmsg"

extern prim-close( db : any ) : fsys ()
  c  "kk_sqlite_close"
  js "_sqlite_close"

extern prim-exec( db : any, sql : string ) : fsys string
  c  "kk_sqlite_exec"
  js "_sqlite_exec"

extern prim-prepare( db : any, sql : string ) : fsys (any, string)
  c  "kk_sqlite_prepare"
  js "_sqlite_prepare"

extern prim-is-null-stmt( st : any ) : fsys bool
  c  "kk_sqlite_is_null_stmt"
  js "_sqlite_is_null_stmt"

extern prim-finalize( st : any ) : fsys ()
  c  "kk_sqlite_finalize"
  js "_sqlite_finalize"

extern prim-param-count( st : any ) : fsys int
  c  "kk_sqlite_param_count"
  js "_sqlite_param_count"

extern prim-bind-null( st : any, i : int ) : fsys int
  c  "kk_sqlite_bind_null"
  js "_sqlite_bind_null"

extern prim-bind-int( st : any, i : int, v : int ) : fsys int
  c  "kk_sqlite_bind_int"
  js "_sqlite_bind_int"

extern prim-bind-float( st : any, i : int, v : float64 ) : fsys int
  c  "kk_sqlite_bind_float"
  js "_sqlite_bind_float"

extern prim-bind-text( st : any, i : int, v : string ) : fsys int
  c  "kk_sqlite_bind_text"
  js "_sqlite_bind_text"

extern prim-bind-blob( st : any, i : int, v : bytes ) : fsys int
  c  "kk_sqlite_bind_blob"
  js "_sqlite_bind_blob"

extern prim-step( st : any ) : fsys int
  c  "kk_sqlite_step"
  js "_sqlite_step"

extern prim-column-count( st : any ) : fsys int
  c  "kk_sqlite_column_count"
  js "_sqlite_column_count"

extern prim-column-name( st : any, i : int ) : fsys string
  c  "kk_sqlite_column_name"
  js "_sqlite_column_name"

extern prim-column-type( st : any, i : int ) : fsys int
  c  "kk_sqlite_column_type"
  js "_sqlite_column_type"

extern prim-column-int( st : any, i : int ) : fsys int
  c  "kk_sqlite_column_int"
  js "_sqlite_column_int"

extern prim-column-float( st : any, i : int ) : fsys float64
  c  "kk_sqlite_column_float"
  js "_sqlite_column_float"

extern prim-column-text( st : any, i : int ) : fsys string
  c  "kk_sqlite_column_text"
  js "_sqlite_column_text"

extern prim-column-blob( st : any, i : int ) : fsys bytes
  c  "kk_sqlite_column_blob"
  js "_sqlite_column_blob"

extern prim-changes( db : any ) : fsys int
  c  "kk_sqlite_changes"
  js "_sqlite_changes"

extern prim-last-rowid( db : any ) : fsys int
  c  "kk_sqlite_last_rowid"
  js "_sqlite_last_rowid"
