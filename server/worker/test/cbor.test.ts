import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { encode as cborEncode } from "cborg";
import { CborError, decodeCbor } from "../src/cbor.ts";

function hexBytes(h: string): Uint8Array {
  return new Uint8Array(h.match(/../g)!.map((b) => parseInt(b, 16)));
}

describe("CBOR decoder", () => {
  it("decodes RFC 8949 Appendix A examples", () => {
    const cases: [string, unknown][] = [
      ["00", 0],
      ["17", 23],
      ["1818", 24],
      ["1903e8", 1000],
      ["1a000f4240", 1000000],
      ["1b000000e8d4a51000", 1000000000000],
      ["20", -1],
      ["3863", -100],
      ["3903e7", -1000],
      ["f4", false],
      ["f5", true],
      ["f6", null],
      ["f7", undefined],
      ["60", ""],
      ["6161", "a"],
      ["6449455446", "IETF"],
      ["62225c", '"\\'],
      ["62c3bc", "ü"],
      ["63e6b0b4", "水"],
      ["80", []],
      ["83010203", [1, 2, 3]],
      ["8301820203820405", [1, [2, 3], [4, 5]]],
    ];
    for (const [h, expected] of cases) assert.deepEqual(decodeCbor(hexBytes(h)), expected, h);

    assert.deepEqual(decodeCbor(hexBytes("40")), new Uint8Array(0));
    assert.deepEqual(decodeCbor(hexBytes("4401020304")), new Uint8Array([1, 2, 3, 4]));
    assert.deepEqual(decodeCbor(hexBytes("a0")), new Map());
    assert.deepEqual(decodeCbor(hexBytes("a201020304")), new Map([[1, 2], [3, 4]]));
    assert.deepEqual(decodeCbor(hexBytes("a26161016162820203")), new Map<string, unknown>([["a", 1], ["b", [2, 3]]]));
    assert.deepEqual(
      decodeCbor(hexBytes("a56161614161626142616361436164614461656145")),
      new Map([["a", "A"], ["b", "B"], ["c", "C"], ["d", "D"], ["e", "E"]]),
    );
  });

  it("round-trips an attestation-shaped object encoded by an independent encoder (cborg)", () => {
    const authData = crypto.getRandomValues(new Uint8Array(200));
    const cert = crypto.getRandomValues(new Uint8Array(700));
    const encoded = cborEncode({ fmt: "apple-appattest", attStmt: { x5c: [cert, cert.slice(0, 500)], receipt: new Uint8Array(3000) }, authData });
    const decoded = decodeCbor(encoded) as Map<string, unknown>;
    assert.equal(decoded.get("fmt"), "apple-appattest");
    assert.deepEqual(decoded.get("authData"), authData);
    const attStmt = decoded.get("attStmt") as Map<string, unknown>;
    const x5c = attStmt.get("x5c") as Uint8Array[];
    assert.equal(x5c.length, 2);
    assert.deepEqual(x5c[0], cert);
    assert.equal((attStmt.get("receipt") as Uint8Array).length, 3000);
  });

  it("rejects malformed or unsupported input", () => {
    const bad: [string, RegExp][] = [
      ["", /unexpected end/],
      ["0001", /trailing bytes/],
      ["5f42010243030405ff", /indefinite/], // indefinite-length byte string
      ["9fff", /indefinite/],
      ["c11a514b67b0", /tags/], // tag 1 (epoch time)
      ["f93c00", /float/], // half-precision 1.0
      ["fb3ff199999999999a", /float/],
      ["1c", /reserved/],
      ["a2616101616102", /duplicate/],
      ["a1f601", /map key/], // null key
      ["62c328", /UTF-8/],
      ["44010203", /unexpected end/], // byte string shorter than declared
      ["9b00000000ffffffff", /unexpected end/], // absurd array length
      ["1bffffffffffffffff", /too large/],
      ["81".repeat(20) + "00", /too deep/],
    ];
    for (const [h, message] of bad) {
      assert.throws(() => decodeCbor(h ? hexBytes(h) : new Uint8Array(0)), (e: unknown) => e instanceof CborError && message.test(e.message), h);
    }
  });
});
