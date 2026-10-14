import assert from "node:assert/strict";
import { before, describe, it } from "node:test";
import { encode as cborEncode } from "cborg";
import { AssertionError, verifyAssertion } from "../src/assertion.ts";
import type { StoredKey } from "../src/assertion.ts";
import { sha256, utf8 } from "../src/encoding.ts";
import { APP_ID, makeAssertion, rawPublicKey } from "./helpers/app-attest.ts";
import { generateEcKeyPair } from "./helpers/webcrypto.ts";

describe("App Attest assertion verification", () => {
  let keys: CryptoKeyPair;
  let stored: StoredKey;
  const body = utf8('{"contents":[{"parts":[{"text":"hello"}]}]}');

  before(async () => {
    keys = await generateEcKeyPair("P-256");
    stored = { publicKey: await rawPublicKey(keys.publicKey), counter: 4, appId: APP_ID };
  });

  async function rejectsWith(code: "invalid_assertion" | "stale_counter", promise: Promise<unknown>, reason?: RegExp) {
    await assert.rejects(promise, (e: unknown) => {
      assert.ok(e instanceof AssertionError);
      assert.equal(e.code, code);
      if (reason) assert.match(e.message, reason);
      return true;
    });
  }

  it("accepts a valid assertion and returns its counter", async () => {
    const assertion = await makeAssertion({ privateKey: keys.privateKey, counter: 5, body });
    assert.equal(await verifyAssertion(assertion, await sha256(body), stored), 5);
  });

  it("binds the signature to the exact body bytes", async () => {
    const assertion = await makeAssertion({ privateKey: keys.privateKey, counter: 5, body });
    const altered = utf8('{"contents":[{"parts":[{"text":"hellO"}]}]}');
    await rejectsWith("invalid_assertion", verifyAssertion(assertion, await sha256(altered), stored), /signature/);
  });

  it("rejects a signature by another key", async () => {
    const other = await generateEcKeyPair("P-256");
    const assertion = await makeAssertion({ privateKey: other.privateKey, counter: 5, body });
    await rejectsWith("invalid_assertion", verifyAssertion(assertion, await sha256(body), stored), /signature/);
  });

  it("rejects a stale or repeated counter", async () => {
    for (const counter of [4, 3, 0]) {
      const assertion = await makeAssertion({ privateKey: keys.privateKey, counter, body });
      await rejectsWith("stale_counter", verifyAssertion(assertion, await sha256(body), stored));
    }
  });

  it("rejects a wrong rpId (assertion made for another app)", async () => {
    const assertion = await makeAssertion({ privateKey: keys.privateKey, counter: 5, body, appId: "ABCDE12345.com.example.other" });
    await rejectsWith("invalid_assertion", verifyAssertion(assertion, await sha256(body), stored), /rpIdHash/);
  });

  it("rejects malformed assertions", async () => {
    const hash = await sha256(body);
    await rejectsWith("invalid_assertion", verifyAssertion(new Uint8Array([0x01]), hash, stored));
    await rejectsWith("invalid_assertion", verifyAssertion(cborEncode({ signature: new Uint8Array(70), authenticatorData: new Uint8Array(37) }), hash, stored));
    await rejectsWith("invalid_assertion", verifyAssertion(cborEncode({ signature: new Uint8Array(8), authenticatorData: new Uint8Array(10) }), hash, stored), /too short/);
  });
});
