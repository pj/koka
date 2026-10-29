/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* URLs (RFC 3986): parsing, building, query strings, and resolving relative references.

   ```
   val u = parse-url("https://user@example.com:8080/a/b?x=1&y=two%20words#top").unjust
   u.host            // "example.com"
   u.port            // Just(8080)
   u.query-params    // [("x","1"),("y","two words")]
   u.resolve("../c").show   // "https://user@example.com:8080/c"
   ```

   The `path`, `query` and `fragment` fields hold the raw (percent-encoded)
   text; use `query-params` and `std/text/encoding/percent-decode` to decode.
*/
module std/net/url

import std/core/undiv
import std/text/encoding

// A parsed URL (or relative reference when `scheme` is empty).
pub struct url
  scheme : string = ""        // for example `https` (lower case)
  userinfo : string = ""      // for example `user:password`
  host : string = ""          // host name or IP address (IPv6 without brackets)
  port : maybe<int> = Nothing
  path : string = ""          // raw path, for example `/a/b%20c`
  query : string = ""         // raw query without the `?`
  fragment : string = ""      // raw fragment without the `#`
  has-authority : bool = False
  has-query : bool = False
  has-fragment : bool = False

// Parse a URL or relative reference. Returns `Nothing` if it is malformed.
pub fun parse-url( s : string ) : maybe<url>
  // scheme
  val (scheme, rest1) = match s.find(":")
    Just(sl) ->
      val sch = sl.before.string
      if sch.is-scheme then (sch.to-lower, sl.after.string) else ("", s)
    Nothing -> ("", s)
  // fragment
  val (rest2, fragment, has-fragment) = match rest1.find("#")
    Just(sl) -> (sl.before.string, sl.after.string, True)
    Nothing -> (rest1, "", False)
  // query
  val (rest3, query, has-query) = match rest2.find("?")
    Just(sl) -> (sl.before.string, sl.after.string, True)
    Nothing -> (rest2, "", False)
  // authority
  match rest3.starts-with("//")
    Just(auth-slice) ->
      val auth-path = auth-slice.string
      val (authority, path) = match auth-path.find("/")
        Just(sl) -> (sl.before.string, "/" ++ sl.after.string)
        Nothing -> (auth-path, "")
      val (userinfo, hostport) = match authority.find-last("@")
        Just(sl) -> (sl.before.string, sl.after.string)
        Nothing -> ("", authority)
      match parse-host-port(hostport)
        Just((host, port)) ->
          Just(Url(scheme, userinfo, host, port, path, query, fragment, True, has-query, has-fragment))
        Nothing -> Nothing
    Nothing ->
      Just(Url(scheme, "", "", Nothing, rest3, query, fragment, False, has-query, has-fragment))

fun is-scheme( s : string ) : bool
  match s.list
    Cons(c, cs) -> c.is-alpha && cs.all(fn(d) d.is-alpha-num || d == '+' || d == '-' || d == '.')
    Nil -> False

fun parse-host-port( hp : string ) : maybe<(string, maybe<int>)>
  if hp.starts-with("[").is-just then
    // IPv6 literal
    match hp.find("]")
      Just(sl) ->
        val host = sl.before.string.list.drop(1).string
        val rest = sl.after.string
        if rest.is-empty then Just((host, Nothing))
        else match rest.starts-with(":")
          Just(p) -> parse-port(p.string).map(fn(port) (host, port))
          Nothing -> Nothing
      Nothing -> Nothing
  else match hp.find-last(":")
    Just(sl) -> parse-port(sl.after.string).map(fn(port) (sl.before.string.to-lower, port))
    Nothing -> Just((hp.to-lower, Nothing))

fun parse-port( s : string ) : maybe<maybe<int>>
  if s.is-empty then Just(Nothing)
  elif s.list.all(is-digit) then parse-int(s).map(Just)
  else Nothing

// Convert a URL back to a string.
pub fun url/show( u : url ) : string
  val sch = if u.scheme.is-empty then "" else u.scheme ++ ":"
  val auth = if !u.has-authority && u.host.is-empty then ""
             else "//" ++ (if u.userinfo.is-empty then "" else u.userinfo ++ "@") ++
                  (if u.host.list.any(fn(c) c == ':') then "[" ++ u.host ++ "]" else u.host) ++
                  (match u.port { Just(p) -> ":" ++ p.show; Nothing -> "" })
  val q = if u.has-query || !u.query.is-empty then "?" ++ u.query else ""
  val f = if u.has-fragment || !u.fragment.is-empty then "#" ++ u.fragment else ""
  sch ++ auth ++ u.path ++ q ++ f

// The port, or the default port for well known schemes (`http`: 80, `https`: 443, ...).
pub fun effective-port( u : url ) : maybe<int>
  match u.port
    Just(p) -> Just(p)
    Nothing -> match u.scheme
      "http" -> Just(80)
      "https" -> Just(443)
      "ws" -> Just(80)
      "wss" -> Just(443)
      "ftp" -> Just(21)
      _ -> Nothing

// The decoded query parameters (`+` is decoded as a space).
pub fun query-params( u : url ) : list<(string, string)>
  parse-query(u.query)

// Parse a query string `a=1&b=two+words` into decoded key-value pairs.
pub fun parse-query( q : string ) : list<(string, string)>
  if q.is-empty then [] else
    q.split("&").filter(fn(p) !p.is-empty).map fn(p)
      match p.find("=")
        Just(sl) -> (sl.before.string.decode-component, sl.after.string.decode-component)
        Nothing -> (p.decode-component, "")

fun decode-component( s : string ) : string
  s.percent-decode(plus-as-space=True).default(s)

// Encode key-value pairs as a query string.
pub fun encode-query( params : list<(string, string)> ) : string
  params.map(fn((k, v)) k.percent-encode ++ "=" ++ v.percent-encode).join("&")

// Look up the (first) value of a query parameter.
pub fun query-param( u : url, name : string ) : maybe<string>
  u.query-params.lookup(fn(k) k == name)

// Replace the query of a URL by the given parameters.
pub fun with-query-params( u : url, params : list<(string, string)> ) : url
  u(query = params.encode-query, has-query = !params.is-empty)

// Resolve a reference relative to a base URL (RFC 3986, section 5.2).
pub fun resolve( base : url, reference : string ) : url
  match parse-url(reference)
    Nothing -> base
    Just(r) ->
      if !r.scheme.is-empty then r(path = r.path.remove-dot-segments)
      elif r.has-authority then r(scheme = base.scheme, path = r.path.remove-dot-segments)
      elif r.path.is-empty then
        if r.has-query then base(query = r.query, has-query = True, fragment = r.fragment, has-fragment = r.has-fragment)
        else base(fragment = r.fragment, has-fragment = r.has-fragment)
      else
        val path = if r.path.starts-with("/").is-just then r.path.remove-dot-segments
                   else merge-paths(base, r.path).remove-dot-segments
        base(path = path, query = r.query, has-query = r.has-query, fragment = r.fragment, has-fragment = r.has-fragment)

fun merge-paths( base : url, rel : string ) : string
  if base.has-authority && base.path.is-empty then "/" ++ rel
  else match base.path.find-last("/")
    Just(sl) -> sl.before.string ++ "/" ++ rel
    Nothing -> rel

// Remove `.` and `..` segments from a path.
pub fun remove-dot-segments( path : string ) : string
  if path.is-empty then return path
  val absolute = path.starts-with("/").is-just
  val segs = path.split("/")
  val segs' = if absolute then segs.drop(1) else segs
  val trailing = match segs'.last
    Just(".") -> True
    Just("..") -> True
    _ -> False
  val out = segs'.foldl([]) fn(acc, seg)
    match seg
      "." -> acc
      ".." -> acc.drop(1)
      _ -> Cons(seg, acc)
  val joined = out.reverse.join("/")
  val res = if trailing && !joined.is-empty then joined ++ "/" else joined
  if absolute then "/" ++ res else res
