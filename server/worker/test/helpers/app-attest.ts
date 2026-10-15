// Builds App Attest test material the way a device and Apple would: a generated root → intermediate → credential
// certificate chain (@peculiar/x509, an independent DER encoder), attestation objects and assertions (cborg, an
// independent CBOR encoder). The Worker's verifier gets the generated root injected in place of Apple's.

import * as x509 from "@peculiar/x509";
import { encode as cborEncode } from "cborg";
import { AAGUID_DEVELOPMENT, AAGUID_PRODUCTION } from "../../src/attestation.ts";
import { b64encode, concat, sha256, utf8 } from "../../src/encoding.ts";
import { exportKeyBytes, generateEcKeyPair } from "./webcrypto.ts";

x509.cryptoProvider.set(crypto);

export const TEAM_ID = "ABCDE12345";
export const BUNDLE_ID = "com.smartschedule.app";
export const APP_ID = `${TEAM_ID}.${BUNDLE_ID}`;
export const NONCE_OID = "1.2.840.113635.100.8.2";

const DAY = 24 * 3600_000;

export interface Ca {
  keys: CryptoKeyPair;
  cert: x509.X509Certificate;
  pem: string;
}

export interface Chain {
  root: Ca;
  intermediate: Ca;
}

const ecKeys = generateEcKeyPair;

/** Root (P-384, self-signed) and intermediate (P-384, SHA-384), shaped like Apple's App Attestation CAs. */
export async function makeChain(now: number, name = "Test App Attestation"): Promise<Chain> {
  const rootKeys = await ecKeys("P-384");
  const rootCert = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01",
    name: `CN=${name} Root CA, O=Test Inc., ST=California`,
    notBefore: new Date(now - 365 * DAY),
    notAfter: new Date(now + 20 * 365 * DAY),
    keys: rootKeys,
    signingAlgorithm: { name: "ECDSA", hash: "SHA-384" },
    extensions: [
      new x509.BasicConstraintsExtension(true, undefined, true),
      new x509.KeyUsagesExtension(x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign, true),
    ],
  });
  const intKeys = await ecKeys("P-384");
  const intCert = await x509.X509CertificateGenerator.create({
    serialNumber: "02",
    subject: `CN=${name} CA 1, O=Test Inc., ST=California`,
    issuer: rootCert.subject,
    notBefore: new Date(now - 30 * DAY),
    notAfter: new Date(now + 5 * 365 * DAY),
    publicKey: intKeys.publicKey,
    signingKey: rootKeys.privateKey,
    signingAlgorithm: { name: "ECDSA", hash: "SHA-384" },
    extensions: [
      new x509.BasicConstraintsExtension(true, 0, true),
      new x509.KeyUsagesExtension(x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign, true),
    ],
  });
  return {
    root: { keys: rootKeys, cert: rootCert, pem: rootCert.toString("pem") },
    intermediate: { keys: intKeys, cert: intCert, pem: intCert.toString("pem") },
  };
}

/** SEQUENCE { [1] EXPLICIT OCTET STRING nonce } for a 32-byte nonce. */
export function nonceExtensionValue(nonce: Uint8Array): Uint8Array {
  if (nonce.length !== 32) throw new Error("nonce must be 32 bytes");
  return concat(new Uint8Array([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]), nonce);
}

export async function rawPublicKey(key: CryptoKey): Promise<Uint8Array> {
  return exportKeyBytes("raw", key);
}

export interface AttestationOptions {
  chain: Chain;
  now: number;
  challenge: Uint8Array;
  appId?: string;
  environment?: "development" | "production";
  counter?: number;
  aaguid?: Uint8Array;
  /** credentialId in authData (defaults to the real keyId). */
  credentialId?: Uint8Array;
  /** Replace the nonce placed in the credential certificate. */
  nonceOverride?: Uint8Array;
  leafNotBefore?: number;
  leafNotAfter?: number;
  /** Sign the credential certificate with this key instead of the intermediate's (issuer name unchanged). */
  leafSigningKey?: CryptoKey;
}

export interface Attestation {
  credentialKeys: CryptoKeyPair;
  keyId: Uint8Array;
  keyIdB64: string;
  attestation: Uint8Array;
  authData: Uint8Array;
  leaf: x509.X509Certificate;
}

export async function makeAttestation(o: AttestationOptions): Promise<Attestation> {
  const credentialKeys = await ecKeys("P-256");
  const point = await rawPublicKey(credentialKeys.publicKey);
  const keyId = await sha256(point);

  const credentialId = o.credentialId ?? keyId;
  const counter = new Uint8Array(4);
  new DataView(counter.buffer).setUint32(0, o.counter ?? 0);
  const credIdLength = new Uint8Array(2);
  new DataView(credIdLength.buffer).setUint16(0, credentialId.length);
  const coseKey = cborEncode(new Map<number, unknown>([[1, 2], [3, -7], [-1, 1], [-2, point.slice(1, 33)], [-3, point.slice(33)]]));
  const authData = concat(
    await sha256(utf8(o.appId ?? APP_ID)),
    new Uint8Array([0x40]),
    counter,
    o.aaguid ?? ((o.environment ?? "development") === "production" ? AAGUID_PRODUCTION : AAGUID_DEVELOPMENT),
    credIdLength,
    credentialId,
    coseKey,
  );

  const clientDataHash = await sha256(o.challenge);
  const nonce = o.nonceOverride ?? (await sha256(concat(authData, clientDataHash)));

  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: "0a1b2c",
    subject: `CN=${Array.from(keyId, (b) => b.toString(16).padStart(2, "0")).join("")}, OU=AAA Certification, O=Test Inc., ST=California`,
    issuer: o.chain.intermediate.cert.subject,
    notBefore: new Date(o.leafNotBefore ?? o.now - 3600_000),
    notAfter: new Date(o.leafNotAfter ?? o.now + 3 * DAY),
    publicKey: credentialKeys.publicKey,
    signingKey: o.leafSigningKey ?? o.chain.intermediate.keys.privateKey,
    signingAlgorithm: { name: "ECDSA", hash: "SHA-256" },
    extensions: [
      new x509.BasicConstraintsExtension(false, undefined, true),
      new x509.KeyUsagesExtension(x509.KeyUsageFlags.digitalSignature, true),
      new x509.Extension(NONCE_OID, false, nonceExtensionValue(nonce)),
    ],
  });

  const attestation = cborEncode({
    fmt: "apple-appattest",
    attStmt: {
      x5c: [new Uint8Array(leaf.rawData), new Uint8Array(o.chain.intermediate.cert.rawData)],
      receipt: utf8("test receipt"),
    },
    authData,
  });
  return { credentialKeys, keyId, keyIdB64: b64encode(keyId), attestation, authData, leaf };
}

/** IEEE P1363 r ‖ s → DER ECDSA-Sig-Value (what the Secure Enclave returns), written independently of src/der.ts. */
export function rawToDerSignature(raw: Uint8Array): Uint8Array {
  const half = raw.length / 2;
  const int = (bytes: Uint8Array): Uint8Array => {
    let i = 0;
    while (i < bytes.length - 1 && bytes[i] === 0) i++;
    let v: Uint8Array = bytes.slice(i);
    if (v[0]! & 0x80) v = concat(new Uint8Array([0]), v);
    return concat(new Uint8Array([0x02, v.length]), v);
  };
  const body = concat(int(raw.subarray(0, half)), int(raw.subarray(half)));
  return concat(new Uint8Array([0x30, body.length]), body);
}

export interface AssertionOptions {
  privateKey: CryptoKey;
  counter: number;
  body: Uint8Array;
  appId?: string;
}

/** CBOR { signature, authenticatorData } as DCAppAttestService.generateAssertion produces. */
export async function makeAssertion(o: AssertionOptions): Promise<Uint8Array> {
  const counter = new Uint8Array(4);
  new DataView(counter.buffer).setUint32(0, o.counter);
  const authenticatorData = concat(await sha256(utf8(o.appId ?? APP_ID)), new Uint8Array([0x40]), counter);
  const nonce = await sha256(concat(authenticatorData, await sha256(o.body)));
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, o.privateKey, nonce));
  return cborEncode({ signature: rawToDerSignature(raw), authenticatorData });
}

/** Authorization: Bearer base64(keyId(32) ‖ assertion). */
export function bearer(keyId: Uint8Array, assertion: Uint8Array): string {
  return `Bearer ${b64encode(concat(keyId, assertion))}`;
}
