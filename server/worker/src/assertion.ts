// App Attest assertion verification — Apple, "Validating apps that connect to your server" › assertions.
//
//   assertion (CBOR) = { signature: DER ECDSA-Sig-Value, authenticatorData }
//   authenticatorData = rpIdHash(32) ‖ flags(1) ‖ counter(4, BE)
//   clientDataHash = SHA256(raw request body); nonce = SHA256(authenticatorData ‖ clientDataHash)
//   signature = ECDSA P-256 / SHA-256 over nonce, by the attested key.

import { CborError, asMap, decodeCbor, getBytes } from "./cbor.ts";
import { DerError, ecdsaDerToRaw } from "./der.ts";
import { bytesEqual, concat, readUint32BE, sha256, utf8 } from "./encoding.ts";

export type AssertionFailure = "invalid_assertion" | "stale_counter";

export class AssertionError extends Error {
  readonly code: AssertionFailure;
  constructor(code: AssertionFailure, reason: string) {
    super(reason);
    this.name = "AssertionError";
    this.code = code;
  }
}

export interface StoredKey {
  /** Uncompressed P-256 point (65 bytes). */
  publicKey: Uint8Array;
  counter: number;
  appId: string;
}

/** Returns the assertion's counter (the new value to store) or throws AssertionError. */
export async function verifyAssertion(assertion: Uint8Array, clientDataHash: Uint8Array, key: StoredKey): Promise<number> {
  let signatureDer: Uint8Array;
  let authenticatorData: Uint8Array;
  try {
    const map = asMap(decodeCbor(assertion), "assertion");
    signatureDer = getBytes(map, "signature");
    authenticatorData = getBytes(map, "authenticatorData");
  } catch (e) {
    if (e instanceof CborError) throw new AssertionError("invalid_assertion", e.message);
    throw e;
  }
  if (authenticatorData.length < 37) throw new AssertionError("invalid_assertion", "authenticatorData too short");

  // 1–3. nonce = SHA256(authenticatorData ‖ clientDataHash); verify the signature over nonce with the stored key.
  const nonce = await sha256(concat(authenticatorData, clientDataHash));
  let rawSignature: Uint8Array;
  try {
    rawSignature = ecdsaDerToRaw(signatureDer, 32);
  } catch (e) {
    if (e instanceof DerError) throw new AssertionError("invalid_assertion", `signature malformed (${e.message})`);
    throw e;
  }
  const publicKey = await crypto.subtle.importKey("raw", key.publicKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, rawSignature, nonce);
  if (!valid) throw new AssertionError("invalid_assertion", "signature does not verify");

  // 4. rpIdHash == SHA256(appId stored at attestation).
  if (!bytesEqual(authenticatorData.subarray(0, 32), await sha256(utf8(key.appId)))) {
    throw new AssertionError("invalid_assertion", "rpIdHash does not match the stored appId");
  }

  // 5. counter strictly greater than the stored one.
  const counter = readUint32BE(authenticatorData, 33);
  if (counter <= key.counter) throw new AssertionError("stale_counter", `counter ${counter} <= stored ${key.counter}`);
  return counter;
}
