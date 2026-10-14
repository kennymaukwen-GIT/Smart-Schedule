// X.509 v3 certificate parsing and ECDSA chain verification (RFC 5280 subset) for the App Attest chain:
// credential certificate → Apple App Attestation CA 1 → Apple App Attestation Root CA (embedded trust anchor).
//
// Supported: ecdsa-with-SHA256 / ecdsa-with-SHA384 signatures by P-256 / P-384 keys. Anything else is rejected.

import type { DerElement } from "./der.ts";
import {
  DerError,
  TAG,
  children,
  decodeBitString,
  decodeBoolean,
  decodeOid,
  decodeSmallInteger,
  decodeTime,
  ecdsaDerToRaw,
  expectTag,
  parseDer,
} from "./der.ts";
import { b64decode, bytesEqual } from "./encoding.ts";

export const OID = {
  ecPublicKey: "1.2.840.10045.2.1",
  p256: "1.2.840.10045.3.1.7",
  p384: "1.3.132.0.34",
  ecdsaWithSHA256: "1.2.840.10045.4.3.2",
  ecdsaWithSHA384: "1.2.840.10045.4.3.3",
  basicConstraints: "2.5.29.19",
  keyUsage: "2.5.29.15",
  extKeyUsage: "2.5.29.37",
  subjectKeyIdentifier: "2.5.29.14",
  authorityKeyIdentifier: "2.5.29.35",
  subjectAltName: "2.5.29.17",
  certificatePolicies: "2.5.29.32",
  appAttestNonce: "1.2.840.113635.100.8.2",
} as const;

/** Critical extensions this verifier understands; any other critical extension fails verification (RFC 5280 §4.2). */
const HANDLED_CRITICAL = new Set<string>([
  OID.basicConstraints,
  OID.keyUsage,
  OID.extKeyUsage,
  OID.subjectKeyIdentifier,
  OID.authorityKeyIdentifier,
  OID.subjectAltName,
  OID.certificatePolicies,
  OID.appAttestNonce,
]);

const KEY_USAGE_KEY_CERT_SIGN = 0x04; // bit 5 of the first octet (bit 0 is the MSB)

export class CertificateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CertificateError";
  }
}

export interface Extension {
  critical: boolean;
  /** extnValue OCTET STRING contents (the DER of the extension's own structure). */
  value: Uint8Array;
}

export interface Certificate {
  der: Uint8Array;
  tbs: Uint8Array;
  signatureAlgorithm: string;
  signature: Uint8Array;
  /** Raw DER of the issuer and subject Names, compared byte for byte when chaining. */
  issuer: Uint8Array;
  subject: Uint8Array;
  notBefore: number;
  notAfter: number;
  /** id-ecPublicKey curve OID. */
  curve: string;
  /** The SubjectPublicKey BIT STRING contents: an uncompressed EC point (0x04 ‖ X ‖ Y). */
  publicKey: Uint8Array;
  extensions: Map<string, Extension>;
  basicConstraints: { ca: boolean; pathLen?: number } | null;
  /** First two octets of the KeyUsage BIT STRING, or null when absent. */
  keyUsage: Uint8Array | null;
}

export function parseCertificate(der: Uint8Array): Certificate {
  try {
    return parseCertificateUnchecked(der);
  } catch (e) {
    if (e instanceof DerError) throw new CertificateError(`malformed certificate (${e.message})`);
    throw e;
  }
}

function parseAlgorithmIdentifier(element: DerElement): string {
  const parts = children(expectTag(element, TAG.SEQUENCE, "AlgorithmIdentifier"));
  // ECDSA signature algorithms have absent parameters (RFC 5758 §3.2).
  if (parts.length !== 1) throw new CertificateError("unexpected AlgorithmIdentifier parameters");
  return decodeOid(parts[0]!);
}

function parseCertificateUnchecked(der: Uint8Array): Certificate {
  const cert = expectTag(parseDer(der), TAG.SEQUENCE, "Certificate");
  const [tbsEl, sigAlgEl, sigEl, ...rest] = children(cert);
  if (rest.length) throw new CertificateError("extra fields in Certificate");
  const tbs = expectTag(tbsEl, TAG.SEQUENCE, "TBSCertificate");
  const signatureAlgorithm = parseAlgorithmIdentifier(sigAlgEl!);
  const signature = decodeBitString(sigEl!, true).bytes;

  const fields = children(tbs);
  let i = 0;
  // version [0] EXPLICIT INTEGER: must be v3 (2) since we rely on extensions.
  const versionEl = fields[i];
  if (!versionEl || versionEl.tag !== 0xa0) throw new CertificateError("not an X.509 v3 certificate");
  const versionInner = children(versionEl);
  if (versionInner.length !== 1 || decodeSmallInteger(versionInner[0]!) !== 2) {
    throw new CertificateError("not an X.509 v3 certificate");
  }
  i++;
  expectTag(fields[i++], TAG.INTEGER, "serialNumber");
  const innerSigAlg = fields[i++]!;
  if (!bytesEqual(innerSigAlg.raw, sigAlgEl!.raw)) throw new CertificateError("signature algorithm mismatch");
  const issuer = expectTag(fields[i++], TAG.SEQUENCE, "issuer").raw;
  const validity = children(expectTag(fields[i++], TAG.SEQUENCE, "validity"));
  if (validity.length !== 2) throw new CertificateError("bad validity");
  const notBefore = decodeTime(validity[0]!);
  const notAfter = decodeTime(validity[1]!);
  const subject = expectTag(fields[i++], TAG.SEQUENCE, "subject").raw;

  const spki = children(expectTag(fields[i++], TAG.SEQUENCE, "subjectPublicKeyInfo"));
  if (spki.length !== 2) throw new CertificateError("bad subjectPublicKeyInfo");
  const keyAlg = children(expectTag(spki[0], TAG.SEQUENCE, "subjectPublicKeyInfo.algorithm"));
  if (keyAlg.length !== 2 || decodeOid(keyAlg[0]!) !== OID.ecPublicKey) {
    throw new CertificateError("public key is not an EC key");
  }
  const curve = decodeOid(keyAlg[1]!);
  const publicKey = decodeBitString(spki[1]!, true).bytes;
  const expectedLength = curve === OID.p256 ? 65 : curve === OID.p384 ? 97 : 0;
  if (!expectedLength) throw new CertificateError(`unsupported curve ${curve}`);
  if (publicKey.length !== expectedLength || publicKey[0] !== 0x04) {
    throw new CertificateError("public key is not an uncompressed point");
  }

  const extensions = new Map<string, Extension>();
  for (; i < fields.length; i++) {
    const field = fields[i]!;
    if (field.tag === 0x81 || field.tag === 0x82) continue; // issuer/subject unique IDs (unused)
    if (field.tag !== 0xa3) throw new CertificateError("unexpected TBSCertificate field");
    const list = children(field);
    if (list.length !== 1) throw new CertificateError("bad extensions wrapper");
    for (const extEl of children(expectTag(list[0], TAG.SEQUENCE, "Extensions"))) {
      const parts = children(expectTag(extEl, TAG.SEQUENCE, "Extension"));
      if (parts.length < 2 || parts.length > 3) throw new CertificateError("bad Extension");
      const oid = decodeOid(parts[0]!);
      let critical = false;
      // An explicit FALSE is not strict DER (DEFAULT values are omitted) but is common; accept it.
      if (parts.length === 3) critical = decodeBoolean(parts[1]!);
      const value = expectTag(parts[parts.length - 1], TAG.OCTET_STRING, "extnValue").value;
      if (extensions.has(oid)) throw new CertificateError(`duplicate extension ${oid}`);
      extensions.set(oid, { critical, value });
    }
  }

  let basicConstraints: Certificate["basicConstraints"] = null;
  const bc = extensions.get(OID.basicConstraints);
  if (bc) {
    const parts = children(expectTag(parseDer(bc.value), TAG.SEQUENCE, "BasicConstraints"));
    let ca = false;
    let pathLen: number | undefined;
    for (const part of parts) {
      if (part.tag === TAG.BOOLEAN) ca = decodeBoolean(part);
      else if (part.tag === TAG.INTEGER) pathLen = decodeSmallInteger(part);
      else throw new CertificateError("bad BasicConstraints");
    }
    basicConstraints = pathLen === undefined ? { ca } : { ca, pathLen };
  }

  let keyUsage: Uint8Array | null = null;
  const ku = extensions.get(OID.keyUsage);
  if (ku) {
    const bits = decodeBitString(parseDer(ku.value), false).bytes;
    keyUsage = new Uint8Array([bits[0] ?? 0, bits[1] ?? 0]);
  }

  return {
    der,
    tbs: tbs.raw,
    signatureAlgorithm,
    signature,
    issuer,
    subject,
    notBefore,
    notAfter,
    curve,
    publicKey,
    extensions,
    basicConstraints,
    keyUsage,
  };
}

export function pemToDer(pem: string): Uint8Array {
  const m = /-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----/.exec(pem);
  if (!m) throw new CertificateError("no PEM certificate block");
  const der = b64decode(m[1]!.replace(/\s+/g, ""));
  if (!der) throw new CertificateError("bad PEM base64");
  return der;
}

function curveParams(curve: string): { namedCurve: "P-256" | "P-384"; size: number } {
  if (curve === OID.p256) return { namedCurve: "P-256", size: 32 };
  if (curve === OID.p384) return { namedCurve: "P-384", size: 48 };
  throw new CertificateError(`unsupported curve ${curve}`);
}

/** Verifies that `issuer`'s key signed `cert`. */
export async function verifySignedBy(cert: Certificate, issuer: Certificate): Promise<boolean> {
  const hash =
    cert.signatureAlgorithm === OID.ecdsaWithSHA256
      ? "SHA-256"
      : cert.signatureAlgorithm === OID.ecdsaWithSHA384
        ? "SHA-384"
        : null;
  if (!hash) throw new CertificateError(`unsupported signature algorithm ${cert.signatureAlgorithm}`);
  const { namedCurve, size } = curveParams(issuer.curve);
  let raw: Uint8Array;
  try {
    raw = ecdsaDerToRaw(cert.signature, size);
  } catch {
    return false;
  }
  const key = await crypto.subtle.importKey("raw", issuer.publicKey, { name: "ECDSA", namedCurve }, false, ["verify"]);
  return crypto.subtle.verify({ name: "ECDSA", hash }, key, raw, cert.tbs);
}

function checkValidity(cert: Certificate, now: number, name: string, skewMs: number): void {
  if (now + skewMs < cert.notBefore) throw new CertificateError(`${name} not yet valid`);
  if (now > cert.notAfter) throw new CertificateError(`${name} expired`);
}

function checkCriticalExtensions(cert: Certificate, name: string): void {
  for (const [oid, ext] of cert.extensions) {
    if (ext.critical && !HANDLED_CRITICAL.has(oid)) throw new CertificateError(`${name} has unhandled critical extension ${oid}`);
  }
}

function checkCa(cert: Certificate, name: string, minPathLen: number): void {
  if (!cert.basicConstraints?.ca) throw new CertificateError(`${name} is not a CA`);
  const pathLen = cert.basicConstraints.pathLen;
  if (pathLen !== undefined && pathLen < minPathLen) throw new CertificateError(`${name} path length too small`);
  if (cert.keyUsage && (cert.keyUsage[0]! & KEY_USAGE_KEY_CERT_SIGN) === 0) {
    throw new CertificateError(`${name} key usage lacks keyCertSign`);
  }
}

/** Allowance for clock differences when a freshly issued credential certificate arrives. */
const NOT_BEFORE_SKEW_MS = 60_000;

/**
 * Validates leaf → intermediate → root, where `root` is the trust anchor supplied by the server (never one sent by
 * the client). Checks names, signatures, validity periods at `now`, CA constraints and critical extensions.
 * Throws CertificateError with the reason on failure.
 */
export async function verifyChain(leaf: Certificate, intermediate: Certificate, root: Certificate, now: number): Promise<void> {
  checkValidity(root, now, "root", 0);
  checkValidity(intermediate, now, "intermediate", NOT_BEFORE_SKEW_MS);
  checkValidity(leaf, now, "credential certificate", NOT_BEFORE_SKEW_MS);

  checkCa(root, "root", 1);
  checkCa(intermediate, "intermediate", 0);
  if (leaf.basicConstraints?.ca) throw new CertificateError("credential certificate must not be a CA");

  checkCriticalExtensions(intermediate, "intermediate");
  checkCriticalExtensions(leaf, "credential certificate");

  if (!bytesEqual(intermediate.issuer, root.subject)) throw new CertificateError("intermediate not issued by root");
  if (!bytesEqual(leaf.issuer, intermediate.subject)) throw new CertificateError("credential certificate not issued by intermediate");

  if (!(await verifySignedBy(intermediate, root))) throw new CertificateError("intermediate signature invalid");
  if (!(await verifySignedBy(leaf, intermediate))) throw new CertificateError("credential certificate signature invalid");
}
