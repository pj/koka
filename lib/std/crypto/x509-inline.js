/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/

// Signature verification with Node's `crypto`.
var _crypto = null;
if ($std_core.host()=="node") {
  _crypto = await import("crypto");
}

// hash: 1 = SHA-1, 256, 384, 512, 0 = none (Ed25519). Returns 1 if valid, 0 if not, -1 if not supported.
export function _x509_verify( spki, hash, data, sig ) {
  if (!_crypto) return -1;
  try {
    const key = _crypto.createPublicKey({ key: Buffer.from(spki), format: "der", type: "spki" });
    const alg = (hash === 0 ? null : "sha" + (hash === 1 ? "1" : String(hash)));
    return (_crypto.verify(alg, Buffer.from(data), key, Buffer.from(sig)) ? 1 : 0);
  }
  catch(exn) {
    return -1;
  }
}
