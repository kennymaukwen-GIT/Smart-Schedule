// Byte helpers shared by every module: base64 (standard and URL-safe), hex, concatenation, SHA-256 and
// constant-time comparison. No dependencies beyond the Web platform (atob/btoa, TextEncoder, WebCrypto).

const STD_BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

/** Standard base64 with padding (what Swift's `base64EncodedString()` writes). */
export function b64encode(bytes: Uint8Array): string {
  let binary = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

/** Strict standard base64 with padding; returns null for anything else (whitespace, URL-safe alphabet, bad padding). */
export function b64decode(text: string): Uint8Array | null {
  if (!STD_BASE64.test(text)) return null;
  let binary: string;
  try {
    binary = atob(text);
  } catch {
    return null;
  }
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/** base64url without padding (JWS). */
export function b64urlEncode(bytes: Uint8Array): string {
  return b64encode(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function b64urlDecode(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null;
  const std = text.replace(/-/g, "+").replace(/_/g, "/");
  return b64decode(std + "=".repeat((4 - (std.length % 4)) % 4));
}

export function hex(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += b.toString(16).padStart(2, "0");
  return s;
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  let length = 0;
  for (const p of parts) length += p.length;
  const out = new Uint8Array(length);
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

const encoder = new TextEncoder();

export function utf8(text: string): Uint8Array {
  return encoder.encode(text);
}

export function utf8Length(text: string): number {
  return encoder.encode(text).length;
}

export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data));
}

/** Constant-time for equal lengths; different lengths return false (lengths are not secret where this is used). */
export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

/** Constant-time string comparison that also hides the length: compares SHA-256 digests. */
export async function timingSafeStringEqual(a: string, b: string): Promise<boolean> {
  const [da, db] = await Promise.all([sha256(utf8(a)), sha256(utf8(b))]);
  return bytesEqual(da, db);
}

export function readUint32BE(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset]! << 24) >>> 0) + (bytes[offset + 1]! << 16) + (bytes[offset + 2]! << 8) + bytes[offset + 3]!;
}
