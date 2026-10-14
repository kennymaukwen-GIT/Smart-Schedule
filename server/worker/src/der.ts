// Minimal strict DER (X.690) reader: enough ASN.1 for X.509 certificates and ECDSA signatures.
// Low-tag-number form only; definite, minimally encoded lengths only (DER rules); no trailing bytes where a
// complete element is expected.

export class DerError extends Error {
  constructor(message: string) {
    super(`der: ${message}`);
    this.name = "DerError";
  }
}

export const TAG = {
  BOOLEAN: 0x01,
  INTEGER: 0x02,
  BIT_STRING: 0x03,
  OCTET_STRING: 0x04,
  NULL: 0x05,
  OID: 0x06,
  UTF8_STRING: 0x0c,
  SEQUENCE: 0x30,
  SET: 0x31,
  UTC_TIME: 0x17,
  GENERALIZED_TIME: 0x18,
} as const;

export interface DerElement {
  /** The identifier octet, e.g. 0x30 for SEQUENCE, 0xa0 for [0] constructed. */
  tag: number;
  /** The complete TLV encoding (a view into the input). */
  raw: Uint8Array;
  /** The contents octets (a view into the input). */
  value: Uint8Array;
}

/** Reads one TLV at `offset`; returns it and the offset just past it. */
export function readElement(bytes: Uint8Array, offset: number): { element: DerElement; next: number } {
  const start = offset;
  if (offset >= bytes.length) throw new DerError("unexpected end");
  const tag = bytes[offset++]!;
  if ((tag & 0x1f) === 0x1f) throw new DerError("high tag numbers not supported");
  if (offset >= bytes.length) throw new DerError("unexpected end");
  let length = bytes[offset++]!;
  if (length === 0x80) throw new DerError("indefinite length not allowed");
  if (length > 0x80) {
    const count = length & 0x7f;
    if (count > 4) throw new DerError("length too large");
    if (offset + count > bytes.length) throw new DerError("unexpected end");
    if (bytes[offset] === 0) throw new DerError("non-minimal length");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[offset++]!;
    if (length < 0x80) throw new DerError("non-minimal length");
  }
  if (length > bytes.length - offset) throw new DerError("length exceeds input");
  const value = bytes.subarray(offset, offset + length);
  const next = offset + length;
  return { element: { tag, raw: bytes.subarray(start, next), value }, next };
}

/** Parses `bytes` as exactly one element. */
export function parseDer(bytes: Uint8Array): DerElement {
  const { element, next } = readElement(bytes, 0);
  if (next !== bytes.length) throw new DerError("trailing bytes");
  return element;
}

/** The elements inside a constructed element (SEQUENCE, SET, explicit tag). */
export function children(element: DerElement): DerElement[] {
  if ((element.tag & 0x20) === 0) throw new DerError("not a constructed element");
  const out: DerElement[] = [];
  let offset = 0;
  while (offset < element.value.length) {
    const { element: child, next } = readElement(element.value, offset);
    out.push(child);
    offset = next;
  }
  return out;
}

export function expectTag(element: DerElement | undefined, tag: number, what: string): DerElement {
  if (!element) throw new DerError(`missing ${what}`);
  if (element.tag !== tag) {
    throw new DerError(`${what}: expected tag 0x${tag.toString(16)}, got 0x${element.tag.toString(16)}`);
  }
  return element;
}

export function decodeOid(element: DerElement): string {
  expectTag(element, TAG.OID, "OID");
  const v = element.value;
  if (v.length === 0) throw new DerError("empty OID");
  const arcs: number[] = [];
  let n = 0;
  let first = true;
  for (let i = 0; i < v.length; i++) {
    const b = v[i]!;
    if (n === 0 && b === 0x80) throw new DerError("non-minimal OID arc");
    n = n * 128 + (b & 0x7f);
    if (n > Number.MAX_SAFE_INTEGER) throw new DerError("OID arc too large");
    if ((b & 0x80) === 0) {
      if (first) {
        const a = n < 40 ? 0 : n < 80 ? 1 : 2;
        arcs.push(a, n - a * 40);
        first = false;
      } else {
        arcs.push(n);
      }
      n = 0;
    } else if (i === v.length - 1) {
      throw new DerError("truncated OID");
    }
  }
  return arcs.join(".");
}

/** A non-negative INTEGER's magnitude with leading zero bytes removed. Negative values are rejected. */
export function decodeUnsignedInteger(element: DerElement): Uint8Array {
  expectTag(element, TAG.INTEGER, "INTEGER");
  const v = element.value;
  if (v.length === 0) throw new DerError("empty INTEGER");
  if (v[0]! & 0x80) throw new DerError("negative INTEGER");
  if (v.length > 1 && v[0] === 0 && (v[1]! & 0x80) === 0) throw new DerError("non-minimal INTEGER");
  let i = 0;
  while (i < v.length - 1 && v[i] === 0) i++;
  return v.subarray(i);
}

export function decodeSmallInteger(element: DerElement): number {
  const magnitude = decodeUnsignedInteger(element);
  if (magnitude.length > 4) throw new DerError("INTEGER too large");
  let n = 0;
  for (const b of magnitude) n = n * 256 + b;
  return n;
}

export function decodeBoolean(element: DerElement): boolean {
  expectTag(element, TAG.BOOLEAN, "BOOLEAN");
  if (element.value.length !== 1) throw new DerError("bad BOOLEAN length");
  const b = element.value[0]!;
  if (b === 0x00) return false;
  if (b === 0xff) return true;
  throw new DerError("non-DER BOOLEAN");
}

/** BIT STRING contents with the unused-bits octet checked; `requireOctetAligned` for keys and signatures. */
export function decodeBitString(element: DerElement, requireOctetAligned: boolean): { bytes: Uint8Array; unusedBits: number } {
  expectTag(element, TAG.BIT_STRING, "BIT STRING");
  const v = element.value;
  if (v.length === 0) throw new DerError("empty BIT STRING");
  const unusedBits = v[0]!;
  if (unusedBits > 7 || (v.length === 1 && unusedBits !== 0)) throw new DerError("bad BIT STRING padding");
  if (requireOctetAligned && unusedBits !== 0) throw new DerError("BIT STRING not octet aligned");
  return { bytes: v.subarray(1), unusedBits };
}

/** UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ), as RFC 5280 requires; epoch milliseconds. */
export function decodeTime(element: DerElement): number {
  const text = String.fromCharCode(...element.value);
  let m: RegExpExecArray | null;
  let year: number;
  if (element.tag === TAG.UTC_TIME) {
    m = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
    if (!m) throw new DerError("bad UTCTime");
    const yy = Number(m[1]);
    year = yy >= 50 ? 1900 + yy : 2000 + yy;
  } else if (element.tag === TAG.GENERALIZED_TIME) {
    m = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
    if (!m) throw new DerError("bad GeneralizedTime");
    year = Number(m[1]);
  } else {
    throw new DerError("expected a time");
  }
  const [month, day, hour, minute, second] = [m[2], m[3], m[4], m[5], m[6]].map(Number) as [number, number, number, number, number];
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) {
    throw new DerError("time out of range");
  }
  const ms = Date.UTC(year, month - 1, day, hour, minute, second);
  if (new Date(ms).getUTCDate() !== day) throw new DerError("invalid calendar date");
  return ms;
}

/**
 * ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER } → the fixed-width r ‖ s that WebCrypto verifies
 * (IEEE P1363). `size` is the curve's field size in bytes (32 for P-256, 48 for P-384).
 */
export function ecdsaDerToRaw(signature: Uint8Array, size: number): Uint8Array {
  const seq = expectTag(parseDer(signature), TAG.SEQUENCE, "ECDSA-Sig-Value");
  const parts = children(seq);
  if (parts.length !== 2) throw new DerError("ECDSA-Sig-Value must have two INTEGERs");
  const out = new Uint8Array(size * 2);
  parts.forEach((part, i) => {
    const n = decodeUnsignedInteger(part);
    if (n.length > size) throw new DerError("ECDSA integer too large");
    if (n.every((b) => b === 0)) throw new DerError("ECDSA integer is zero");
    out.set(n, i * size + (size - n.length));
  });
  return out;
}
