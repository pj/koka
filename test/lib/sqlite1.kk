// std/db/sqlite
import std/db/sqlite
import std/os/fs
import std/num/float64

fun main()
  println(sqlite-version().split(".").length == 3)
  with-database(":memory:") fn(db)
    db.exec("create table person(id integer primary key, name text not null, age int, score real, photo blob);" ++
            "create index person_name on person(name)")
    println(db.execute("insert into person(name, age, score, photo) values (?, ?, ?, ?)", ["ada".sql, 36.sql, 1.5.sql, "\x01\x02".bytes.sql]))
    println(db.last-insert-rowid)
    db.execute("insert into person(name, age) values (?, ?)", ["bob".sql, SqlNull])
    db.execute("insert into person(name, age) values (?, ?)", ["O'Brien; drop table person; --".sql, Just(51).sql])
    db.query("select id, name, age, score, photo from person order by id").foreach(fn(r) println(r.show))
    val r = db.query-one("select * from person where name = ?", ["ada".sql]).default(Row([], []))
    println((r.int("id"), r.text("name"), r.int("age")))
    println((r.float("score"), r.blob("photo").map(fn(b) b.length), r.is-null("missing")))
    println(db.query-value("select count(*) from person"))
    println(db.query-value("select age from person where name = 'bob'").map(show))
    println(db.query("select 1 + 1 as two, 'x' || 'y' as xy, null as n, 2.5 * 2 as f, 9007199254740993 as big").map(show))
    println(db.execute("update person set age = age + 1 where age is not null"))
    // query-each reads rows one at a time
    var names := []
    db.query-each("select name from person where age > ? order by name", [40.sql]) fn(row)
      names := Cons(row.text("name").default(""), names)
    println(names.reverse)
    // transactions
    db.transaction { db.execute("insert into person(name) values ('cy')") }
    println(try({ db.transaction { db.execute("insert into person(name) values ('dee')"); throw("rollback please") } }).is-error)
    println(db.query("select name from person order by id").map(fn(row) row.text("name").default("")))
    // errors
    println(catch-message({ db.execute("insert into nosuch values (1)"); "ok" }))
    println(catch-message({ db.execute("insert into person(name) values (null)"); "ok" }))
    println(catch-message({ db.query("selec 1"); "ok" }))
    println(try({ db.execute("insert into person(name, age) values (?, ?)", ["only one".sql]) }).is-error)
    println(catch-message({ db.exec("create table person(x)"); "ok" }))
  // a database file persists
  with-temp-dir fn(dir)
    val f = (dir / "test.db").string
    with-database(f) fn(db)
      db.exec("create table kv(k text primary key, v text)")
      list(1, 100).foreach(fn(i) { db.execute("insert into kv values (?, ?)", [("k" ++ i.show).sql, i.show.sql]); () })
    with-database(f) fn(db)
      println(db.query-value("select sum(cast(v as int)) from kv"))
    println(try({ open-database((dir / "no" / "such" / "dir.db").string) }).is-error)

fun catch-message( action : () -> <fsys,exn,console> string ) : <fsys,console> string
  match try(action)
    Ok(s) -> s
    Error(e) -> e.message
