/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.
---------------------------------------------------------------------------*/
var _crypto = null;
if ($std_core.host()=="node") {
  _crypto = await import("crypto");
}

export function _sha_digest( data, sha256 ) {
  if (!_crypto) throw new Error("std/crypto/hash requires Node.js");
  const buf = _crypto.createHash(sha256 ? "sha256" : "sha1").update(data).digest();
  return new Uint8Array(buf.buffer, buf.byteOffset, buf.length);
}
