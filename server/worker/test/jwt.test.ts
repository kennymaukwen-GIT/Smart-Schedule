import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";
import { b64encode, b64urlDecode, utf8 } from "../src/encoding.ts";
import { JWT_KV_KEY, apnsJwt, importP8, resetJwtCacheForTests } from "../src/jwt.ts";
import { makeHarness } from "./helpers/harness.ts";
import { exportKeyBytes, generateEcKeyPair } from "./helpers/webcrypto.ts";

async function makeP8(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const keys = await generateEcKeyPair("P-256");
  const pkcs8 = await exportKeyBytes("pkcs8", keys.privateKey);
  const lines = b64encode(pkcs8).match(/.{1,64}/g)!.join("\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`, publicKey: keys.publicKey };
}

function decodePart(part: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(b64urlDecode(part)!)) as Record<string, unknown>;
}

describe("APNs provider JWT (ES256)", () => {
  beforeEach(() => resetJwtCacheForTests());

  it("is signed with the .p8 key and verifies with its public key", async () => {
    const { pem, publicKey } = await makeP8();
    const h = makeHarness({ env: { APNS_PRIVATE_KEY: pem } });
    const deps = { now: () => h.clock.now, fetch: fetch, rootCaPem: "", sleep: async () => {} };
    const jwt = await apnsJwt(h.env, deps);
    const [header, claims, signature] = jwt.split(".") as [string, string, string];
    assert.deepEqual(decodePart(header), { alg: "ES256", kid: "KEYID12345" });
    assert.deepEqual(decodePart(claims), { iss: "ABCDE12345", iat: Math.floor(h.clock.now / 1000) });
    const raw = b64urlDecode(signature)!;
    assert.equal(raw.length, 64); // JWS ES256 is raw r ‖ s, not DER
    assert.ok(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, raw, utf8(`${header}.${claims}`)));
  });

  it("reuses one token for up to 50 minutes, shared through KV, then mints a new one", async () => {
    const { pem } = await makeP8();
    const h = makeHarness({ env: { APNS_PRIVATE_KEY: pem } });
    const deps = { now: () => h.clock.now, fetch: fetch, rootCaPem: "", sleep: async () => {} };
    const first = await apnsJwt(h.env, deps);
    assert.ok(await h.kv.get(JWT_KV_KEY));

    h.clock.now += 49 * 60_000;
    assert.equal(await apnsJwt(h.env, deps), first);
    resetJwtCacheForTests(); // another isolate: finds it in KV
    assert.equal(await apnsJwt(h.env, deps), first);

    h.clock.now += 2 * 60_000; // 51 minutes after iat
    const second = await apnsJwt(h.env, deps);
    assert.notEqual(second, first);
    assert.equal(decodePart(second.split(".")[1]!).iat, Math.floor(h.clock.now / 1000));
  });

  it("accepts a .p8 pasted with escaped newlines and rejects garbage", async () => {
    const { pem } = await makeP8();
    await importP8(pem.replace(/\n/g, "\\n"));
    await assert.rejects(importP8("-----BEGIN PRIVATE KEY-----\nnot base64!\n-----END PRIVATE KEY-----"));
  });
});
