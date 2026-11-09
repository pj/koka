/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

/* X.509 certificates: the fields needed to check them and to ask about
   their revocation (see `std/async/os/ocsp`), and signature verification.

   ```
   import std/crypto/x509

   fun main()
     val certs = x509-pem(read-text-file("chain.pem".path))
     match certs
       Cons(leaf, Cons(issuer, _)) ->
         println(leaf.subject-name)
         println(leaf.is-signed-by(issuer))
         println(leaf.ocsp-urls)
       _ -> ()
   ```

   Signatures with RSA (PKCS #1 v1.5) and ECDSA, with SHA-1 or SHA-2, are
   checked with mbedtls on the C backend and Node's `crypto` on JavaScript
   (which also checks Ed25519).
*/
module std/crypto/x509

import std/data/der
import std/num/int32

// (all three, in the order of std/async/api/uv/tls: with static linking,
// libraries are listed in the order modules first name them, and GNU ld
// needs mbedcrypto after the others)
extern import
  c[host=libc] { vcpkg="mbedtls"; library="mbedtls" }

extern import
  c[host=libc] { vcpkg="mbedtls"; library="mbedx509" }

extern import
  c[host=libc] { vcpkg="mbedtls"; library="mbedcrypto" }

extern import
  c  file "x509-inline.c"
  js file "x509-inline.js"

// An X.509 certificate.
pub struct certificate
  der : bytes                 // the whole certificate
  tbs : bytes                 // the signed part ("to be signed"), as encoded
  serial : int
  issuer : bytes              // the issuer's name, as encoded
  subject : bytes             // the subject's name, as encoded
  public-key : bytes          // the SubjectPublicKeyInfo, as encoded
  not-before : string         // as written (UTCTime or GeneralizedTime)
  not-after : string
  extensions : list<(string, bool, bytes)>   // (OID, critical, value)
  signature-algorithm : string               // OID
  signature : bytes

// Parse a certificate in DER.
pub fun x509( b : bytes ) : exn certificate
  match b.elements
    [tbs, alg, sig] ->
      val tbs-parts = tbs.elements
      // the version ([0] EXPLICIT) is optional
      val fields = match tbs-parts
        Cons(first, rest) | first.byte0 == 0xA0 -> rest
        _ -> tbs-parts
      match fields
        Cons(serial, Cons(_, Cons(issuer, Cons(validity, Cons(subject, Cons(spki, rest)))))) ->
          val (nb, na) = match validity.decode
            Der-seq([Der-time(_, a), Der-time(_, z)]) -> (a, z)
            _ -> throw("x509: invalid validity")
          val exts = rest.find(fn(r) r.byte0 == 0xA3).map(fn(r) r.decode.explicit.extension-list).default([])
          val sig-alg = match alg.decode
            Der-seq(Cons(Der-oid(o), _)) -> o
            _ -> throw("x509: invalid signature algorithm")
          val signature = match sig.decode
            Der-bits(bits, 0) -> bits
            _ -> throw("x509: invalid signature")
          val sn = match serial.decode
            Der-int(n) -> n
            _ -> throw("x509: invalid serial number")
          Certificate(b, tbs, sn, issuer, subject, spki, nb, na, exts, sig-alg, signature)
        _ -> throw("x509: invalid certificate")
    _ -> throw("x509: invalid certificate")

fun byte0( b : bytes ) : int
  if b.length == 0 then -1 else b.unsafe-index(0.ssize_t).int

fun extension-list( d : der ) : exn list<(string, bool, bytes)>
  match d
    Der-seq(exts) -> exts.map fn(e)
      match e
        Der-seq([Der-oid(o), Der-octets(v)]) -> (o, False, v)
        Der-seq([Der-oid(o), Der-bool(c), Der-octets(v)]) -> (o, c, v)
        _ -> throw("x509: invalid extension")
    _ -> throw("x509: invalid extensions")

// The certificates in a PEM text, in order.
pub fun x509-pem( text : string ) : exn list<certificate>
  pem-decode(text, "CERTIFICATE").map(x509)

// The value of an extension.
pub fun extension( c : certificate, oid : string ) : maybe<bytes>
  c.extensions.find(fn((o, _, _)) o == oid).map(fn((_, _, v)) v)

// The URLs of the OCSP responders (from the Authority Information Access
// extension).
pub fun ocsp-urls( c : certificate ) : list<string>
  match c.extension("1.3.6.1.5.5.7.1.1")
    Nothing -> []
    Just(v) -> match try({ v.decode })
      Ok(Der-seq(descs)) -> descs.flatmap fn(desc)
        match desc
          Der-seq([Der-oid("1.3.6.1.5.5.7.48.1"), Der-tagged(2, 6, False, url)]) -> [url.string]
          _ -> []
      _ -> []

// The extended key usages (OIDs), if the certificate restricts them.
pub fun extended-key-usage( c : certificate ) : maybe<list<string>>
  match c.extension("2.5.29.37")
    Nothing -> Nothing
    Just(v) -> match try({ v.decode })
      Ok(Der-seq(oids)) -> Just(oids.flatmap(fn(o) match o { Der-oid(s) -> [s]; _ -> [] }))
      _ -> Just([])

// The common name (CN) of a name, or the whole name in a readable form.
pub fun name-text( name : bytes ) : string
  match try({ name.decode })
    Ok(Der-seq(rdns)) ->
      val parts = rdns.flatmap fn(rdn)
        match rdn
          Der-set(atvs) -> atvs.flatmap fn(atv)
            match atv
              Der-seq([Der-oid(o), Der-string(_, s)]) -> [(attr-name(o), s)]
              _ -> []
          _ -> []
      parts.map(fn((n, v)) n ++ "=" ++ v).join(", ")
    _ -> "?"

fun attr-name( oid : string ) : string
  match oid
    "2.5.4.3"  -> "CN"
    "2.5.4.6"  -> "C"
    "2.5.4.7"  -> "L"
    "2.5.4.8"  -> "ST"
    "2.5.4.10" -> "O"
    "2.5.4.11" -> "OU"
    _ -> oid

pub fun subject-name( c : certificate ) : string
  c.subject.name-text

pub fun issuer-name( c : certificate ) : string
  c.issuer.name-text

// The public key bits (inside the SubjectPublicKeyInfo).
pub fun public-key-bits( c : certificate ) : exn bytes
  match c.public-key.decode
    Der-seq([_, Der-bits(bits, 0)]) -> bits
    _ -> throw("x509: invalid public key")

// Is `c` signed by the key of `ca` (and issued by its subject)?
pub fun is-signed-by( c : certificate, ca : certificate ) : exn bool
  c.issuer == ca.subject && verify-signature(ca.public-key, c.signature-algorithm, c.tbs, c.signature)

fun bytes/(==)( a : bytes, b : bytes ) : bool
  a.length == b.length && list(0, a.length - 1).all(fn(i) a.unsafe-index(i.ssize_t).int == b.unsafe-index(i.ssize_t).int)

// Verify a signature made with the key `public-key` (a SubjectPublicKeyInfo
// in DER) over `data`, with the signature algorithm `algorithm` (an OID, as
// in certificates). Raises an exception for an unsupported algorithm or key.
pub fun verify-signature( public-key : bytes, algorithm : string, data : bytes, signature : bytes ) : exn bool
  val hash = match algorithm
    "1.2.840.113549.1.1.5"  -> 1     // sha1WithRSAEncryption
    "1.2.840.113549.1.1.11" -> 256   // sha256WithRSAEncryption
    "1.2.840.113549.1.1.12" -> 384
    "1.2.840.113549.1.1.13" -> 512
    "1.2.840.10045.4.1"     -> 1     // ecdsa-with-SHA1
    "1.2.840.10045.4.3.2"   -> 256   // ecdsa-with-SHA256
    "1.2.840.10045.4.3.3"   -> 384
    "1.2.840.10045.4.3.4"   -> 512
    "1.3.101.112"           -> 0     // Ed25519
    _ -> throw("x509: unsupported signature algorithm " ++ algorithm)
  match x509-verify(public-key, hash.int32, data, signature).int
    1 -> True
    0 -> False
    _ -> throw("x509: unsupported key or signature algorithm " ++ algorithm)

extern x509-verify( spki : bytes, hash : int32, data : bytes, sig : bytes ) : int32
  c  "kk_x509_verify"
  js "_x509_verify"
