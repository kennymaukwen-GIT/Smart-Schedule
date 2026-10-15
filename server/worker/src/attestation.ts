// App Attest attestation verification — Apple, "Validating apps that connect to your server", steps 1–9.
//
//   attestation object (CBOR) = { fmt: "apple-appattest", attStmt: { x5c: [credCert, intermediate], receipt }, authData }
//   authData = rpIdHash(32) ‖ flags(1) ‖ signCount(4, BE) ‖ aaguid(16) ‖ credIdLen(2, BE) ‖ credentialId ‖ COSE key
//
// The client calls attestKey(keyId, clientDataHash: SHA256(challengeBytes)), so clientDataHash is computed here
// from the server-issued challenge bytes.

import { CborError, asMap, decodeCbor, getArray, getBytes, getText } from "./cbor.ts";
import { DerError, TAG, children, expectTag, parseDer } from "./der.ts";
import { bytesEqual, concat, sha256, utf8 } from "./encoding.ts";
import type { Certificate } from "./x509.ts";
import { CertificateError, OID, parseCertificate, pemToDer, verifyChain } from "./x509.ts";

export type AttestEnvironment = "development" | "production";

/** "appattestdevelop" */
export const AAGUID_DEVELOPMENT = utf8("appattestdevelop");
/** "appattest" followed by seven 0x00 bytes */
export const AAGUID_PRODUCTION = concat(utf8("appattest"), new Uint8Array(7));

export class AttestationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AttestationError";
  }
}

export interface AttestationInput {
  /** Raw key identifier bytes (base64-decoded keyId): SHA-256 of the credential public key. */
  keyId: Uint8Array;
  /** The CBOR attestation object bytes. */
  attestation: Uint8Array;
  /** The one-time challenge bytes the server issued. */
  challenge: Uint8Array;
  /** `<teamId>.<bundleId>` */
  appId: string;
  environment: AttestEnvironment;
  /** The trusted root (parsed from the embedded Apple PEM; tests inject their own). */
  root: Certificate;
  now: number;
}

export interface VerifiedAttestation {
  /** Credential public key as a 65-byte uncompressed P-256 point. */
  publicKey: Uint8Array;
  receipt: Uint8Array;
}

export function loadRoot(pem: string): Certificate {
  return parseCertificate(pemToDer(pem));
}

interface AuthData {
  rpIdHash: Uint8Array;
  signCount: number;
  aaguid: Uint8Array;
  credentialId: Uint8Array;
}

function parseAuthData(authData: Uint8Array): AuthData {
  // 32 + 1 + 4 + 16 + 2 = 55 bytes before the credential ID.
  if (authData.length < 55) throw new AttestationError("authData too short");
  const view = new DataView(authData.buffer, authData.byteOffset, authData.byteLength);
  const credIdLength = view.getUint16(53);
  if (authData.length < 55 + credIdLength) throw new AttestationError("authData credentialId truncated");
  return {
    rpIdHash: authData.subarray(0, 32),
    signCount: view.getUint32(33),
    aaguid: authData.subarray(37, 53),
    credentialId: authData.subarray(55, 55 + credIdLength),
  };
}

/** Extension 1.2.840.113635.100.8.2: SEQUENCE { [1] EXPLICIT OCTET STRING nonce }. */
function extractNonce(credCert: Certificate): Uint8Array {
  const ext = credCert.extensions.get(OID.appAttestNonce);
  if (!ext) throw new AttestationError("credential certificate lacks the nonce extension");
  try {
    const seq = expectTag(parseDer(ext.value), TAG.SEQUENCE, "nonce extension");
    const items = children(seq);
    if (items.length !== 1) throw new AttestationError("nonce extension: unexpected structure");
    const tagged = expectTag(items[0], 0xa1, "nonce [1]");
    const inner = children(tagged);
    if (inner.length !== 1) throw new AttestationError("nonce extension: unexpected structure");
    return expectTag(inner[0], TAG.OCTET_STRING, "nonce OCTET STRING").value;
  } catch (e) {
    if (e instanceof DerError) throw new AttestationError(`nonce extension malformed (${e.message})`);
    throw e;
  }
}

/**
 * Throws AttestationError (reason in the message) unless every check passes. Every failure — including an
 * unexpected exception while parsing hostile input — is an AttestationError, so a client always gets
 * 401 invalid_attestation and never a 500.
 */
export async function verifyAttestation(input: AttestationInput): Promise<VerifiedAttestation> {
  try {
    return await verify(input);
  } catch (e) {
    if (e instanceof AttestationError) throw e;
    if (e instanceof CborError || e instanceof CertificateError || e instanceof DerError) {
      throw new AttestationError(e.message);
    }
    throw new AttestationError(`unexpected ${e instanceof Error ? `${e.name}: ${e.message}` : String(e)}`);
  }
}

async function verify(input: AttestationInput): Promise<VerifiedAttestation> {
  if (input.keyId.length !== 32) throw new AttestationError("keyId must be 32 bytes");

  const object = asMap(decodeCbor(input.attestation), "attestation object");
  if (getText(object, "fmt") !== "apple-appattest") throw new AttestationError("fmt is not apple-appattest");
  const attStmt = asMap(object.get("attStmt") ?? null, "attStmt");
  const authDataBytes = getBytes(object, "authData");
  const x5c = getArray(attStmt, "x5c");
  const receipt = getBytes(attStmt, "receipt");
  if (x5c.length !== 2) throw new AttestationError(`x5c must hold 2 certificates, has ${x5c.length}`);
  const [credDer, intermediateDer] = x5c;
  if (!(credDer instanceof Uint8Array) || !(intermediateDer instanceof Uint8Array)) {
    throw new AttestationError("x5c entries must be byte strings");
  }

  // 1. Certificate chain credCert → intermediate → Apple root (trust anchor held by the server).
  const credCert = parseCertificate(credDer);
  const intermediate = parseCertificate(intermediateDer);
  await verifyChain(credCert, intermediate, input.root, input.now);

  // 2–3. clientDataHash = SHA256(challenge); nonce = SHA256(authData ‖ clientDataHash).
  const clientDataHash = await sha256(input.challenge);
  const nonce = await sha256(concat(authDataBytes, clientDataHash));

  // 4. The credential certificate's nonce extension must equal nonce.
  if (!bytesEqual(extractNonce(credCert), nonce)) throw new AttestationError("nonce mismatch");

  // 5. SHA256(credential public key, uncompressed point) == keyId.
  if (credCert.curve !== OID.p256) throw new AttestationError("credential key is not P-256");
  if (!bytesEqual(await sha256(credCert.publicKey), input.keyId)) throw new AttestationError("keyId does not match the credential public key");

  const authData = parseAuthData(authDataBytes);

  // 6. rpIdHash == SHA256(appId).
  if (!bytesEqual(authData.rpIdHash, await sha256(utf8(input.appId)))) throw new AttestationError("rpIdHash does not match appId");

  // 7. counter == 0.
  if (authData.signCount !== 0) throw new AttestationError(`sign count is ${authData.signCount}, expected 0`);

  // 8. aaguid matches the configured environment.
  const expectedAaguid = input.environment === "production" ? AAGUID_PRODUCTION : AAGUID_DEVELOPMENT;
  if (!bytesEqual(authData.aaguid, expectedAaguid)) throw new AttestationError(`aaguid does not match the ${input.environment} environment`);

  // 9. credentialId == keyId.
  if (!bytesEqual(authData.credentialId, input.keyId)) throw new AttestationError("credentialId does not match keyId");

  return { publicKey: credCert.publicKey.slice(), receipt };
}
