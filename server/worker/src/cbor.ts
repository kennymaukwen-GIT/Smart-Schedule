// Minimal CBOR (RFC 8949) decoder for App Attest attestation and assertion objects.
//
// Deliberately small and strict: definite lengths only; unsigned/negative integers within the JS safe range;
// byte strings; UTF-8 text strings (invalid UTF-8 rejected); arrays; maps with text or integer keys (duplicates
// rejected); false/true/null/undefined. Tags, floats, other simple values and indefinite lengths are rejected —
// App Attest objects never use them. The whole input must be consumed (no trailing bytes).

export type CborValue =
  | number
  | string
  | boolean
  | null
  | undefined
  | Uint8Array
  | CborValue[]
  | CborMap;

export type CborMap = Map<string | number, CborValue>;

export class CborError extends Error {
  constructor(message: string) {
    super(`cbor: ${message}`);
    this.name = "CborError";
  }
}

const MAX_DEPTH = 16;
const textDecoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

export function decodeCbor(bytes: Uint8Array): CborValue {
  const reader = new Reader(bytes);
  const value = reader.item(0);
  if (reader.offset !== bytes.length) throw new CborError("trailing bytes");
  return value;
}

class Reader {
  offset = 0;
  private readonly bytes: Uint8Array;
  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
  }

  private byte(): number {
    if (this.offset >= this.bytes.length) throw new CborError("unexpected end");
    return this.bytes[this.offset++]!;
  }

  private take(length: number): Uint8Array {
    if (length > this.bytes.length - this.offset) throw new CborError("unexpected end");
    const out = this.bytes.subarray(this.offset, this.offset + length);
    this.offset += length;
    return out;
  }

  /** The argument that follows the initial byte (RFC 8949 §3). */
  private argument(info: number): number {
    if (info < 24) return info;
    if (info === 24) return this.byte();
    if (info === 25) {
      const b = this.take(2);
      return (b[0]! << 8) | b[1]!;
    }
    if (info === 26) {
      const b = this.take(4);
      return b[0]! * 0x1000000 + ((b[1]! << 16) | (b[2]! << 8) | b[3]!);
    }
    if (info === 27) {
      const b = this.take(8);
      let n = 0n;
      for (const x of b) n = (n << 8n) | BigInt(x);
      if (n > BigInt(Number.MAX_SAFE_INTEGER)) throw new CborError("integer too large");
      return Number(n);
    }
    // 28–30 reserved, 31 = indefinite length.
    throw new CborError(info === 31 ? "indefinite length not supported" : "reserved additional info");
  }

  item(depth: number): CborValue {
    if (depth > MAX_DEPTH) throw new CborError("nesting too deep");
    const initial = this.byte();
    const major = initial >> 5;
    const info = initial & 0x1f;
    switch (major) {
      case 0:
        return this.argument(info);
      case 1: {
        const n = this.argument(info);
        if (n >= Number.MAX_SAFE_INTEGER) throw new CborError("integer too large");
        return -1 - n;
      }
      case 2:
        return this.take(this.argument(info)).slice();
      case 3: {
        const raw = this.take(this.argument(info));
        try {
          return textDecoder.decode(raw);
        } catch {
          throw new CborError("invalid UTF-8 in text string");
        }
      }
      case 4: {
        const count = this.argument(info);
        // Every item takes at least one byte: reject impossible counts before allocating.
        if (count > this.bytes.length - this.offset) throw new CborError("unexpected end");
        const out: CborValue[] = [];
        for (let i = 0; i < count; i++) out.push(this.item(depth + 1));
        return out;
      }
      case 5: {
        const count = this.argument(info);
        if (count * 2 > this.bytes.length - this.offset) throw new CborError("unexpected end");
        const map: CborMap = new Map();
        for (let i = 0; i < count; i++) {
          const key = this.item(depth + 1);
          if (typeof key !== "string" && typeof key !== "number") throw new CborError("unsupported map key type");
          if (map.has(key)) throw new CborError("duplicate map key");
          map.set(key, this.item(depth + 1));
        }
        return map;
      }
      case 6:
        throw new CborError("tags not supported");
      default: // 7
        switch (info) {
          case 20:
            return false;
          case 21:
            return true;
          case 22:
            return null;
          case 23:
            return undefined;
          default:
            throw new CborError("unsupported simple value or float");
        }
    }
  }
}

// Typed accessors used by the attestation and assertion parsers.

export function asMap(value: CborValue, what: string): CborMap {
  if (!(value instanceof Map)) throw new CborError(`${what} is not a map`);
  return value;
}

export function getBytes(map: CborMap, key: string): Uint8Array {
  const v = map.get(key);
  if (!(v instanceof Uint8Array)) throw new CborError(`${key} is not a byte string`);
  return v;
}

export function getText(map: CborMap, key: string): string {
  const v = map.get(key);
  if (typeof v !== "string") throw new CborError(`${key} is not a text string`);
  return v;
}

export function getArray(map: CborMap, key: string): CborValue[] {
  const v = map.get(key);
  if (!Array.isArray(v)) throw new CborError(`${key} is not an array`);
  return v;
}
