/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* Certificate revocation checks with OCSP
   ([RFC 6960](https://www.rfc-editor.org/rfc/rfc6960)).

   `ocsp-check` asks the OCSP responder of a certificate (named in the
   certificate) whether it was revoked:

   ```
   import std/async
   import std/async/os/ocsp
   import std/crypto/x509

   fun main()
     val chain = x509-pem(read-text-file("chain.pem".path))
     match chain
       Cons(leaf, Cons(issuer, _)) -> println(ocsp-check(leaf, issuer).show)
       _ -> ()
   ```

   The response must be signed by the issuer, or by a responder certificate
   that the issuer signed for this purpose (`OCSPSigning` usage); its
   `thisUpdate`/`nextUpdate` times must include the current time (with five
   minutes of leeway). A TLS client checks the server certificate with
   `tls-connect(..., ocsp = True)` (see `std/async/os/tls`).

   `ocsp-request` and `ocsp-status` build a request and check a response
   without doing the request, for other transports or for caching.
*/
module async/os/ocsp

import std/core/undiv
import std/data/der
import std/crypto/x509
import std/crypto/hash
import std/time/chrono
import std/time/utc
import std/num/ddouble
import std/net/url
import async/async
import async/os/net

// The revocation status of a certificate.
pub type ocsp-status
  // Not revoked.
  Good
  // Revoked at `time` (GeneralizedTime, `YYYYMMDDHHMMSSZ`), with the CRL reason code if given
  // (1 key compromise, 2 CA compromise, 3 affiliation changed, 4 superseded, 5 cessation of operation, ...).
  Revoked( time : string, reason : maybe<int> )
  // The responder does not know the certificate.
  Unknown

pub fun ocsp-status/show( s : ocsp-status ) : string
  match s
    Good -> "good"
    Revoked(t, r) -> "revoked at " ++ t ++ (match r { Just(n) -> " (" ++ reason-name(n) ++ ")"; Nothing -> "" })
    Unknown -> "unknown"

pub fun ocsp-status/(==)( a : ocsp-status, b : ocsp-status ) : bool
  a.show == b.show

fun reason-name( n : int ) : string
  match n
    0 -> "unspecified"
    1 -> "key compromise"
    2 -> "CA compromise"
    3 -> "affiliation changed"
    4 -> "superseded"
    5 -> "cessation of operation"
    6 -> "certificate hold"
    8 -> "remove from CRL"
    9 -> "privilege withdrawn"
    10 -> "AA compromise"
    _ -> "reason " ++ n.show

val oid-sha1      = "1.3.14.3.2.26"
val oid-sha256    = "2.16.840.1.101.3.4.2.1"
val oid-basic     = "1.3.6.1.5.5.7.48.1.1"
val oid-nonce     = "1.3.6.1.5.5.7.48.1.2"
val oid-ocsp-sign = "1.3.6.1.5.5.7.3.9"

// ----------------------------------------------------------------------------
// Requests
// ----------------------------------------------------------------------------

// The CertID of a certificate: hashes of its issuer's name and key, and its serial number.
fun cert-id( cert : certificate, ca : certificate, hash-oid : string ) : exn der
  val h = if hash-oid == oid-sha1 then sha1 elif hash-oid == oid-sha256 then sha256
          else throw("ocsp: unsupported hash algorithm " ++ hash-oid)
  Der-seq([Der-seq([Der-oid(hash-oid), Der-null]), Der-octets(h(cert.issuer)), Der-octets(h(ca.public-key-bits)), Der-int(cert.serial)])

// An OCSP request (DER) for `cert`, issued by `ca`, with an optional nonce
// (most responders ignore it; a response that echoes it must echo it exactly).
pub fun ocsp-request( cert : certificate, ca : certificate, nonce : bytes = bytes/empty ) : <exn,div> bytes
  val exts = if nonce.is-empty then [] else
    [tag-explicit(2, Der-seq([Der-seq([Der-oid(oid-nonce), Der-octets(Der-octets(nonce).encode)])]))]
  val tbs = Der-seq(Cons(Der-seq([Der-seq([cert-id(cert, ca, oid-sha1)])]), exts))
  Der-seq([tbs]).encode

// ----------------------------------------------------------------------------
// Responses
// ----------------------------------------------------------------------------

// Check an OCSP response (DER) about `cert`, issued by `ca`, and return its
// status. Raises an exception if the response is an error, is not signed
// properly, is not about `cert`, does not echo `nonce` (when it has one), or
// is not current at `now` (Unix seconds; the current time by default).
pub fun ocsp-status( response : bytes, cert : certificate, ca : certificate, nonce : bytes = bytes/empty, now : int = -1 ) : <exn,ndet,div> ocsp-status
  val now-secs = if now >= 0 then now else unix-now()
  val basic = match response.decode
    Der-seq([Der-enum(0), resp-bytes]) -> match resp-bytes.explicit
      Der-seq([Der-oid(t), Der-octets(b)]) | t == oid-basic -> b
      Der-seq([Der-oid(t), _]) -> throw("ocsp: unsupported response type " ++ t)
      _ -> throw("ocsp: invalid response")
    Der-seq(Cons(Der-enum(status), _)) -> throw("ocsp: the responder answered: " ++ response-status-name(status))
    _ -> throw("ocsp: invalid response")
  // BasicOCSPResponse: the signed data is checked as it was received
  val (tbs-raw, sig-alg, signature, certs) = match basic.elements
    Cons(tbs, Cons(alg, Cons(sig, rest))) ->
      val a = match alg.decode
        Der-seq(Cons(Der-oid(o), _)) -> o
        _ -> throw("ocsp: invalid signature algorithm")
      val s = match sig.decode
        Der-bits(bits, 0) -> bits
        _ -> throw("ocsp: invalid signature")
      val cs = match rest
        [cs-raw] -> cs-raw.decode.explicit.elements-of.map(fn(c) x509(c.encode))
        _ -> []
      (tbs, a, s, cs)
    _ -> throw("ocsp: invalid basic response")
  val tbs-parts = match tbs-raw.decode
    Der-seq(parts) -> parts
    _ -> throw("ocsp: invalid response data")
  val fields = match tbs-parts
    Cons(Der-tagged(2, 0, True, _), rest) -> rest   // version
    _ -> tbs-parts
  match fields
    Cons(responder-id, Cons(Der-time(_, _produced), Cons(Der-seq(responses), rest))) ->
      // the signer: the CA itself, or a responder it authorized
      val signer = responder(responder-id, ca, certs, now-secs)
      if !verify-signature(signer.public-key, sig-alg, tbs-raw, signature) then throw("ocsp: the response signature is not valid")
      // the nonce, if both have one
      val exts = rest.find(fn(d) match d { Der-tagged(2, 1, True, _) -> True; _ -> False })
      match exts.map(fn(d) d.explicit)
        Just(Der-seq(es)) | !nonce.is-empty -> es.foreach fn(e)
          match e
            Der-seq(Cons(Der-oid(o), more)) | o == oid-nonce ->
              val v = match more.last
                Just(Der-octets(v)) -> v
                _ -> throw("ocsp: invalid nonce")
              if v != nonce && v != Der-octets(nonce).encode then throw("ocsp: the response does not echo the nonce")
            _ -> ()
        _ -> ()
      // the answer about our certificate
      val single = responses.find-maybe fn(r)
        match r
          Der-seq(Cons(id as Der-seq(Cons(Der-seq(Cons(Der-oid(h), _)), _)), _)) ->
            match try({ cert-id(cert, ca, h) })
              Ok(ours) -> if same-cert-id(ours, id) then Just(r) else Nothing
              _ -> Nothing
          _ -> Nothing
      match single
        Just(Der-seq(Cons(_, Cons(status, Cons(Der-time(_, this-update), more))))) ->
          val skew = 300
          if gen-time(this-update) > now-secs + skew then throw("ocsp: the response is not valid yet (thisUpdate " ++ this-update ++ ")")
          more.foreach fn(m)
            match m
              Der-tagged(2, 0, True, _) -> match m.explicit
                Der-time(_, next-update) ->
                  if gen-time(next-update) < now-secs - skew then throw("ocsp: the response has expired (nextUpdate " ++ next-update ++ ")")
                _ -> ()
              _ -> ()
          match status
            Der-tagged(2, 0, _, _) -> Good
            Der-tagged(2, 1, _, info) -> match Der-tagged(2, 1, True, info).implicit(16)
              Der-seq(Cons(Der-time(_, t), r)) ->
                val reason = match r
                  [x] -> match x.explicit
                    Der-enum(n) -> Just(n)
                    _ -> Nothing
                  _ -> Nothing
                Revoked(t, reason)
              _ -> throw("ocsp: invalid revocation information")
            Der-tagged(2, 2, _, _) -> Unknown
            _ -> throw("ocsp: invalid certificate status")
        _ -> throw("ocsp: the response is not about this certificate")
    _ -> throw("ocsp: invalid response data")

fun elements-of( d : der ) : exn list<der>
  match d
    Der-seq(xs) -> xs
    _ -> throw("ocsp: expected a sequence")

fun same-cert-id( a : der, b : der ) : div bool
  // the hash algorithm parameters may be absent or NULL
  match (a, b)
    (Der-seq([Der-seq(Cons(h1, _)), n1, k1, s1]), Der-seq([Der-seq(Cons(h2, _)), n2, k2, s2])) ->
      h1.encode == h2.encode && n1.encode == n2.encode && k1.encode == k2.encode && s1.encode == s2.encode
    _ -> False

fun bytes/(==)( a : bytes, b : bytes ) : bool
  a.length == b.length && list(0, a.length - 1).all(fn(i) a.unsafe-index(i.ssize_t).int == b.unsafe-index(i.ssize_t).int)

fun bytes/(!=)( a : bytes, b : bytes ) : bool
  !(a == b)

// The certificate that signed a response: `ca` itself, or a certificate in
// the response that `ca` issued for signing OCSP responses.
fun responder( id : der, ca : certificate, certs : list<certificate>, now : int ) : <exn,div> certificate
  fun matches( c : certificate ) : <exn,div> bool
    match id
      Der-tagged(2, 1, True, name) -> name == c.subject
      Der-tagged(2, 2, True, _) -> match id.explicit
        Der-octets(h) -> h == sha1(c.public-key-bits)
        _ -> False
      _ -> throw("ocsp: invalid responder id")
  if matches(ca) then ca
  else match certs.find(fn(c) pretend-no-div { matches(c) })
    Nothing -> throw("ocsp: the response is not signed by the issuer or a responder it authorized")
    Just(c) ->
      if !c.is-signed-by(ca) then throw("ocsp: the responder certificate is not issued by the issuer")
      if !c.extended-key-usage.default([]).any(fn(u) u == oid-ocsp-sign) then
        throw("ocsp: the responder certificate is not authorized to sign OCSP responses")
      if gen-time(c.not-after) < now || gen-time(c.not-before) > now then
        throw("ocsp: the responder certificate is not valid now")
      c

fun response-status-name( n : int ) : string
  match n
    1 -> "malformed request"
    2 -> "internal error"
    3 -> "try later"
    5 -> "signature required"
    6 -> "unauthorized"
    _ -> "status " ++ n.show

// ----------------------------------------------------------------------------
// Time
// ----------------------------------------------------------------------------

fun unix-now() : ndet int
  now-in().unix-timestamp.floor.int   // (leap seconds do not matter here)

// Unix seconds of a GeneralizedTime (`YYYYMMDDHHMMSS[.f]Z`) or UTCTime
// (`YYMMDDHHMMSSZ`, years 1950-2049).
fun gen-time( t : string ) : exn int
  val digits = t.list.take-while(is-digit).string
  val (year, rest) = if digits.count == 12 then
      val yy = digits.first(2).string.parse-int.default(0)
      (if yy < 50 then 2000 + yy else 1900 + yy, digits.list.drop(2).string)
    elif digits.count >= 14 then (digits.first(4).string.parse-int.default(0), digits.list.drop(4).string)
    else throw("ocsp: invalid time " ++ t.show)
  fun num( i : int ) : int
    rest.list.drop(i).take(2).string.parse-int.default(0)
  val days = days-from-civil(year, num(0), num(2))
  ((days * 24 + num(4)) * 60 + num(6)) * 60 + num(8)

// Days since 1970-01-01 (proleptic Gregorian calendar).
fun days-from-civil( y0 : int, m : int, d : int ) : int
  val y = if m <= 2 then y0 - 1 else y0
  val era = (if y >= 0 then y else y - 399) / 400
  val yoe = y - era * 400
  val mp = (m + 9) % 12
  val doy = (153 * mp + 2) / 5 + d - 1
  val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468

// ----------------------------------------------------------------------------
// Checking
// ----------------------------------------------------------------------------

// Ask the OCSP responder of `cert` (the first in the certificate, or `url`)
// whether it was revoked. `ca` is the certificate that issued `cert`. Raises
// an exception if there is no responder, it cannot be reached, or its answer
// is not valid (see `ocsp-status`).
pub fun ocsp-check( cert : certificate, ca : certificate, url : string = "" ) : <async,exn,net,ndet> ocsp-status
  val target = if !url.is-empty then url else match cert.ocsp-urls
    Cons(u, _) -> u
    Nil -> throw("ocsp: the certificate names no OCSP responder")
  val req = pretend-no-div { ocsp-request(cert, ca) }
  val body = post(target, req)
  pretend-no-div { ocsp-status(body, cert, ca) }

// A minimal HTTP/1.0 POST (OCSP responders use plain `http`; this module is
// used by `std/async/os/tls`, so it cannot use `std/async/os/http`).
fun post( target : string, body : bytes ) : <async,exn,net> bytes
  val u = match parse-url(target)
    Just(u) | u.scheme == "http" -> u
    _ -> throw("ocsp: unsupported responder url " ++ target.show)
  val conn-port = u.port.default(80)
  val path = (if u.path.is-empty then "/" else u.path) ++ (if u.has-query then "?" ++ u.query else "")
  with s = tcp-connect(u.host, conn-port)
  val request-head = "POST " ++ path ++ " HTTP/1.0\r\nHost: " ++ u.host ++ (if u.port.is-just then ":" ++ conn-port.show else "") ++
             "\r\nContent-Type: application/ocsp-request\r\nContent-Length: " ++ body.length.show ++ "\r\nConnection: close\r\n\r\n"
  s.write-all(request-head.bytes ++ body)
  val res = s.read-all
  // the status line and headers end with an empty line
  fun find-end( i : int ) : exn int
    if i + 3 >= res.length then -1
    elif res[i] == 13 && res[i+1] == 10 && res[i+2] == 13 && res[i+3] == 10 then i
    else find-end(pretend-decreasing(i + 1))
  val end = catch(fn(_) -1, { find-end(0) })
  if end < 0 then throw("ocsp: invalid HTTP response from the responder")
  val status = res.subbytes(0, end).string.split(" ").drop(1).head.default("").parse-int.default(0)
  if status != 200 then throw("ocsp: the responder answered with HTTP status " ++ status.show)
  res.subbytes(end + 4)
