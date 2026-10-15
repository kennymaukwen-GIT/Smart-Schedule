// App Attest assertion verification — Apple, "Validating apps that connect to your server" › assertions.
//
//   assertion (CBOR) = { signature: DER ECDSA-Sig-Value, authenticatorData }
//   authenticatorData = rpIdHash(32) ‖ flags(1) ‖ counter(4, BE)
//   clientDataHash = SHA256(raw request body); nonce = SHA256(authenticatorData ‖ clientDataHash)
//   signature = ECDSA P-256 / SHA-256 over nonce, by the attested key.
//
// Split in two so the Worker can reject a malformed or foreign assertion before it reads the request body:
// parseAssertion (structure, rpIdHash) needs only the token; checkAssertion (signature, counter) needs the body.

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

export interface ParsedAssertion {
  /** IEEE P1363 r ‖ s (64 bytes). */
  signature: Uint8Array;
  authenticatorData: Uint8Array;
  counter: number;
}

/** Structure and rpIdHash (== SHA256(appId)); throws AssertionError("invalid_assertion"). */
export async function parseAssertion(assertion: Uint8Array, appId: string): Promise<ParsedAssertion> {
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
  if (!bytesEqual(authenticatorData.subarray(0, 32), await sha256(utf8(appId)))) {
    throw new AssertionError("invalid_assertion", "rpIdHash does not match the stored appId");
  }
  let signature: Uint8Array;
  try {
    signature = ecdsaDerToRaw(signatureDer, 32);
  } catch (e) {
    if (e instanceof DerError) throw new AssertionError("invalid_assertion", `signature malformed (${e.message})`);
    throw e;
  }
  return { signature, authenticatorData, counter: readUint32BE(authenticatorData, 33) };
}

/** Signature over nonce with the stored key, then counter > stored. Returns the new counter. */
export async function checkAssertion(parsed: ParsedAssertion, clientDataHash: Uint8Array, key: StoredKey): Promise<number> {
  const nonce = await sha256(concat(parsed.authenticatorData, clientDataHash));
  const publicKey = await crypto.subtle.importKey("raw", key.publicKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, parsed.signature, nonce);
  if (!valid) throw new AssertionError("invalid_assertion", "signature does not verify");
  if (parsed.counter <= key.counter) throw new AssertionError("stale_counter", `counter ${parsed.counter} <= stored ${key.counter}`);
  return parsed.counter;
}

/** Both steps; returns the assertion's counter (the new value to store) or throws AssertionError. */
export async function verifyAssertion(assertion: Uint8Array, clientDataHash: Uint8Array, key: StoredKey): Promise<number> {
  return checkAssertion(await parseAssertion(assertion, key.appId), clientDataHash, key);
}
