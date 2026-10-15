import assert from "node:assert/strict";
import { before, describe, it } from "node:test";
import { b64decode, b64encode, hex, sha256, utf8 } from "../src/encoding.ts";
import { eventHash } from "../src/registration.ts";
import type { Chain } from "./helpers/app-attest.ts";
import { BUNDLE_ID, TEAM_ID, bearer, makeAssertion, makeAttestation, makeChain } from "./helpers/app-attest.ts";
import type { Harness } from "./helpers/harness.ts";
import { START, jsonOf, makeHarness } from "./helpers/harness.ts";
import { generateEcKeyPair } from "./helpers/webcrypto.ts";
import { encode as cborEncode } from "cborg";

let chain: Chain;
before(async () => {
  chain = await makeChain(START);
});

interface Device {
  keyId: Uint8Array;
  keyIdB64: string;
  privateKey: CryptoKey;
  counter: number;
  /** Signs `body` with the next counter and sends it. */
  send(path: string, body?: string | Uint8Array, init?: RequestInit): Promise<Response>;
}

async function attestDevice(h: Harness, bundleId = BUNDLE_ID): Promise<Device> {
  const challengeResponse = await h.request("/attest/challenge");
  assert.equal(challengeResponse.status, 200);
  const { challenge } = (await challengeResponse.json()) as { challenge: string };
  const a = await makeAttestation({ chain, now: h.clock.now, challenge: b64decode(challenge)!, appId: `${TEAM_ID}.${bundleId}` });
  const response = await h.request("/attest", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ keyId: a.keyIdB64, attestation: b64encode(a.attestation), challenge, bundleId }),
  });
  assert.equal(response.status, 200, JSON.stringify(await response.clone().json()));
  const device: Device = {
    keyId: a.keyId,
    keyIdB64: a.keyIdB64,
    privateKey: a.credentialKeys.privateKey,
    counter: 0,
    async send(path, body = "", init = {}) {
      const bytes = typeof body === "string" ? utf8(body) : body;
      device.counter++;
      const assertion = await makeAssertion({ privateKey: device.privateKey, counter: device.counter, body: bytes, appId: `${TEAM_ID}.${bundleId}` });
      const headers = new Headers(init.headers);
      headers.set("authorization", bearer(device.keyId, assertion));
      const method = init.method ?? (bytes.length ? "POST" : "GET");
      return h.request(path, { ...init, method, headers, ...(method === "GET" || method === "HEAD" ? {} : { body: bytes }) });
    },
  };
  return device;
}

describe("GET /attest/challenge", () => {
  it("returns 32 random bytes in standard base64 and stores chal:<challenge> for 300 s", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const body = await jsonOf(await h.request("/attest/challenge"));
    const challenge = body.challenge as string;
    assert.equal(b64decode(challenge)?.length, 32);
    const write = h.kv.writes.find((w) => w.key === `chal:${challenge}`);
    assert.equal(write?.expirationTtl, 300);
  });

  it("is rate-limited per client IP", async () => {
    const h = makeHarness({ env: { RATE_LIMIT_PER_MIN: "2" } });
    const ip = { headers: { "cf-connecting-ip": "203.0.113.7" } };
    assert.equal((await h.request("/attest/challenge", ip)).status, 200);
    assert.equal((await h.request("/attest/challenge", ip)).status, 200);
    const limited = await h.request("/attest/challenge", ip);
    assert.equal(limited.status, 429);
    assert.deepEqual(await limited.json(), { error: "rate_limited" });
    assert.equal((await h.request("/attest/challenge", { headers: { "cf-connecting-ip": "203.0.113.8" } })).status, 200);
  });
});

describe("POST /attest", () => {
  it("verifies the attestation and stores key:<keyId> with counter 0", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const device = await attestDevice(h);
    const record = JSON.parse((await h.kv.get(`key:${device.keyIdB64}`))!) as Record<string, unknown>;
    assert.equal(record.counter, 0);
    assert.equal(record.appId, `${TEAM_ID}.${BUNDLE_ID}`);
    assert.equal(b64decode(record.publicKey as string)?.length, 65);
    assert.equal(record.createdAt, new Date(START).toISOString());
    assert.equal(h.kv.writes.find((w) => w.key === `key:${device.keyIdB64}`)?.expirationTtl, undefined);
    assert.equal(h.kv.keysWithPrefix("chal:").length, 0, "challenge consumed");
  });

  it("accepts the notification content extension's bundle ID", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const device = await attestDevice(h, "com.smartschedule.app.notification-content");
    const record = JSON.parse((await h.kv.get(`key:${device.keyIdB64}`))!) as Record<string, unknown>;
    assert.equal(record.appId, `${TEAM_ID}.com.smartschedule.app.notification-content`);
  });

  async function post(h: Harness, fields: Record<string, unknown>) {
    return h.request("/attest", { method: "POST", body: JSON.stringify(fields) });
  }

  it("rejects unknown and reused challenges with invalid_challenge", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const unknown = b64encode(crypto.getRandomValues(new Uint8Array(32)));
    const a = await makeAttestation({ chain, now: START, challenge: b64decode(unknown)! });
    const fields = { keyId: a.keyIdB64, attestation: b64encode(a.attestation), challenge: unknown, bundleId: BUNDLE_ID };
    let r = await post(h, fields);
    assert.equal(r.status, 401);
    assert.deepEqual(await r.json(), { error: "invalid_challenge" });

    const { challenge } = (await jsonOf(await h.request("/attest/challenge"))) as { challenge: string };
    const b = await makeAttestation({ chain, now: START, challenge: b64decode(challenge)! });
    const good = { keyId: b.keyIdB64, attestation: b64encode(b.attestation), challenge, bundleId: BUNDLE_ID };
    assert.equal((await post(h, good)).status, 200);
    r = await post(h, good);
    assert.equal(r.status, 401);
    assert.deepEqual(await r.json(), { error: "invalid_challenge" });
  });

  it("rejects an expired challenge", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const { challenge } = (await jsonOf(await h.request("/attest/challenge"))) as { challenge: string };
    h.clock.now += 301_000;
    const a = await makeAttestation({ chain, now: h.clock.now, challenge: b64decode(challenge)! });
    const r = await post(h, { keyId: a.keyIdB64, attestation: b64encode(a.attestation), challenge, bundleId: BUNDLE_ID });
    assert.deepEqual(await r.json(), { error: "invalid_challenge" });
  });

  async function attestWith(h: Harness, bundleId: string, appId = `${TEAM_ID}.${bundleId}`) {
    const { challenge } = (await jsonOf(await h.request("/attest/challenge"))) as { challenge: string };
    const a = await makeAttestation({ chain, now: h.clock.now, challenge: b64decode(challenge)!, appId });
    return post(h, { keyId: a.keyIdB64, attestation: b64encode(a.attestation), challenge, bundleId });
  }

  it("rejects a bundle ID outside BUNDLE_IDS and a team ID mismatch with invalid_attestation", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    let r = await attestWith(h, "com.example.evil");
    assert.equal(r.status, 401);
    assert.deepEqual(await r.json(), { error: "invalid_attestation" });
    r = await attestWith(h, BUNDLE_ID, `ZZZZZ99999.${BUNDLE_ID}`);
    assert.equal(r.status, 401);
    assert.deepEqual(await r.json(), { error: "invalid_attestation" });
    assert.equal(h.kv.keysWithPrefix("key:").length, 0);
  });

  it("rejects production attestations while APP_ATTEST_ENV is development (aaguid)", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem, env: { APP_ATTEST_ENV: "production" } });
    const r = await attestWith(h, BUNDLE_ID); // fixture defaults to the development aaguid
    assert.deepEqual(await r.json(), { error: "invalid_attestation" });
  });

  it("fails closed with 500 server_misconfigured while the Apple root CA is not embedded", async () => {
    const h = makeHarness({ rootCaPem: "" });
    const r = await attestWith(h, BUNDLE_ID);
    assert.equal(r.status, 500);
    assert.deepEqual(await r.json(), { error: "server_misconfigured" });
    assert.equal(h.kv.keysWithPrefix("key:").length, 0);
  });

  it("answers 401 invalid_attestation (never 500) for a truncated credential certificate", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const { challenge } = (await jsonOf(await h.request("/attest/challenge"))) as { challenge: string };
    const a = await makeAttestation({ chain, now: START, challenge: b64decode(challenge)! });
    const truncated = new Uint8Array([0x30, 0x19, 0x30, 0x08, 0xa0, 0x03, 0x02, 0x01, 0x02, 0x02, 0x01, 0x01, 0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, 0x03, 0x01, 0x00]);
    const attestation = cborEncode({
      fmt: "apple-appattest",
      attStmt: { x5c: [truncated, new Uint8Array(chain.intermediate.cert.rawData)], receipt: new Uint8Array(1) },
      authData: a.authData,
    });
    const r = await post(h, { keyId: a.keyIdB64, attestation: b64encode(attestation), challenge, bundleId: BUNDLE_ID });
    assert.deepEqual([r.status, await r.json()], [401, { error: "invalid_attestation" }]);
  });

  it("rejects malformed bodies with 400 invalid_request", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    for (const body of ["", "not json", "[]", JSON.stringify({ keyId: "x" })]) {
      const r = await h.request("/attest", { method: "POST", body });
      assert.equal(r.status, 400);
      assert.deepEqual(await r.json(), { error: "invalid_request" });
    }
  });
});

describe("authentication", () => {
  it("accepts a valid assertion, stores the new counter and rejects its replay with stale_counter", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const device = await attestDevice(h);
    const body = utf8('{"contents":[]}');
    const assertion = await makeAssertion({ privateKey: device.privateKey, counter: 1, body });
    const init = { method: "POST", headers: { authorization: bearer(device.keyId, assertion) }, body };
    assert.equal((await h.request("/v1beta/models/gemini-2.5-flash:generateContent", init)).status, 200);
    assert.equal((JSON.parse((await h.kv.get(`key:${device.keyIdB64}`))!) as { counter: number }).counter, 1);

    const replay = await h.request("/v1beta/models/gemini-2.5-flash:generateContent", init);
    assert.equal(replay.status, 401);
    assert.deepEqual(await replay.json(), { error: "stale_counter" });
    assert.equal(h.calls.length, 1, "the replay never reached Gemini");
  });

  it("rejects a bad signature (body changed after signing) with invalid_assertion", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const device = await attestDevice(h);
    const assertion = await makeAssertion({ privateKey: device.privateKey, counter: 1, body: utf8('{"a":1}') });
    const r = await h.request("/v1beta/models/x:generateContent", { method: "POST", headers: { authorization: bearer(device.keyId, assertion) }, body: '{"a":2}' });
    assert.equal(r.status, 401);
    assert.deepEqual(await r.json(), { error: "invalid_assertion" });
  });

  it("returns unknown_key for an unattested key, attestation_required without credentials, invalid_assertion for garbage", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const keys = await generateEcKeyPair("P-256");
    const assertion = await makeAssertion({ privateKey: keys.privateKey, counter: 1, body: new Uint8Array(0) });
    let r = await h.request("/v1beta/models", { headers: { authorization: bearer(crypto.getRandomValues(new Uint8Array(32)), assertion) } });
    assert.deepEqual([r.status, await r.json()], [401, { error: "unknown_key" }]);
    r = await h.request("/v1beta/models");
    assert.deepEqual([r.status, await r.json()], [401, { error: "attestation_required" }]);
    r = await h.request("/v1beta/models", { headers: { authorization: "Bearer !!!" } });
    assert.deepEqual([r.status, await r.json()], [401, { error: "invalid_assertion" }]);
    r = await h.request("/v1beta/models", { headers: { authorization: `Bearer ${b64encode(new Uint8Array(32))}` } });
    assert.deepEqual([r.status, await r.json()], [401, { error: "invalid_assertion" }]);
  });

  it("rejects missing credentials before reading the body", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    let pulled = false;
    const body = new ReadableStream<Uint8Array>(
      {
        pull() {
          pulled = true;
          throw new Error("body must not be read");
        },
      },
      { highWaterMark: 0 }, // pull() runs only when someone reads
    );
    const r = await h.worker.fetch(
      new Request("https://worker.test/v1beta/models/x:generateContent", { method: "POST", body, duplex: "half" } as RequestInit),
      h.env,
      { waitUntil() {} },
    );
    assert.deepEqual([r.status, await r.json()], [401, { error: "attestation_required" }]);
    assert.equal(pulled, false);
  });

  it("answers 503 server_busy when the counter cannot be persisted, without forwarding", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const device = await attestDevice(h);
    h.kv.failPut = (key) => key.startsWith("key:");
    const r = await device.send("/v1beta/models/x:generateContent", "{}");
    assert.deepEqual([r.status, await r.json()], [503, { error: "server_busy" }]);
    assert.equal(h.calls.length, 0);
  });

  /** A request whose body stream records whether anything read it. */
  function streamingRequest(path: string, headers: Record<string, string>, size = 16) {
    const state = { pulled: false };
    const body = new ReadableStream<Uint8Array>(
      {
        pull(controller) {
          state.pulled = true;
          controller.enqueue(new Uint8Array(size));
          controller.close();
        },
      },
      { highWaterMark: 0 }, // pull() runs only when someone reads
    );
    const request = new Request(`https://worker.test${path}`, { method: "POST", body, headers, duplex: "half" } as RequestInit);
    return { request, state };
  }

  it("limits bodies to 2 MB from Content-Length and rejects a body that does not match it", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    const dev = { "x-dev-token": "dev-secret-token" };
    const huge = streamingRequest("/v1beta/models/x:generateContent", { ...dev, "content-length": String(2 * 1024 * 1024 + 1) });
    let r = await h.worker.fetch(huge.request, h.env, { waitUntil() {} });
    assert.deepEqual([r.status, await r.json()], [413, { error: "payload_too_large" }]);
    assert.equal(huge.state.pulled, false, "rejected from the header, nothing read");

    for (const declared of ["10", "3"]) {
      r = await h.request("/v1beta/models/x:generateContent", { method: "POST", headers: { ...dev, "content-length": declared }, body: "12345" });
      assert.deepEqual([r.status, await r.json()], [413, { error: "payload_too_large" }], `declared ${declared}, sent 5`);
    }
    // Without Content-Length (chunked) the body is read up to the limit.
    const chunked = streamingRequest("/v1beta/models/x:generateContent", dev, 2 * 1024 * 1024 + 1);
    r = await h.worker.fetch(chunked.request, h.env, { waitUntil() {} });
    assert.deepEqual([r.status, await r.json()], [413, { error: "payload_too_large" }]);
    const small = streamingRequest("/v1beta/models/x:generateContent", dev, 100);
    r = await h.worker.fetch(small.request, h.env, { waitUntil() {} });
    assert.equal(r.status, 200);
    assert.equal(h.calls.at(-1)!.body!.length, 100);
    assert.equal(h.calls.length, 1);
  });

  it("checks the assertion's key, structure and rpId before reading the body", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const device = await attestDevice(h);
    const foreign = await makeAssertion({ privateKey: device.privateKey, counter: 1, body: new Uint8Array(16), appId: "ABCDE12345.com.example.other" });
    const wrongApp = streamingRequest("/v1beta/models/x:generateContent", { authorization: bearer(device.keyId, foreign), "content-length": "16" });
    let r = await h.worker.fetch(wrongApp.request, h.env, { waitUntil() {} });
    assert.deepEqual([r.status, await r.json()], [401, { error: "invalid_assertion" }]);
    assert.equal(wrongApp.state.pulled, false);

    const unknown = streamingRequest("/v1beta/models/x:generateContent", { authorization: bearer(new Uint8Array(32), foreign), "content-length": "16" });
    r = await h.worker.fetch(unknown.request, h.env, { waitUntil() {} });
    assert.deepEqual([r.status, await r.json()], [401, { error: "unknown_key" }]);
    assert.equal(unknown.state.pulled, false);
  });

  it("rate-limits failed authentications per IP before reading the body", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true", RATE_LIMIT_PER_MIN: "3" } });
    const ip = { "cf-connecting-ip": "203.0.113.9" };
    for (let i = 0; i < 3; i++) {
      const r = await h.request("/v1beta/models", { headers: { ...ip, authorization: "Bearer !!!" } });
      assert.equal(r.status, 401);
    }
    assert.equal(h.kv.writes.find((w) => w.key.startsWith("rl:authfail:203.0.113.9:"))?.expirationTtl, 120);
    const blocked = streamingRequest("/v1beta/models/x:generateContent", { ...ip, "x-dev-token": "dev-secret-token", "content-length": "16" });
    const r = await h.worker.fetch(blocked.request, h.env, { waitUntil() {} });
    assert.equal(r.status, 429);
    assert.deepEqual(await r.json(), { error: "rate_limited" });
    assert.ok(Number(r.headers.get("retry-after")) >= 1);
    assert.equal(blocked.state.pulled, false);

    assert.equal((await h.request("/v1beta/models", { headers: { "cf-connecting-ip": "203.0.113.10", "x-dev-token": "dev-secret-token" } })).status, 200, "other IPs unaffected");
    h.clock.now += 60_000;
    assert.equal((await h.request("/v1beta/models", { headers: { ...ip, "x-dev-token": "dev-secret-token" } })).status, 200, "next minute");
  });

  describe("assertion counter", () => {
    async function storedCounter(h: Harness, keyIdB64: string): Promise<number> {
      return (JSON.parse((await h.kv.get(`key:${keyIdB64}`))!) as { counter: number }).counter;
    }

    function setCounter(h: Harness, keyIdB64: string, counter: number): void {
      const key = `key:${keyIdB64}`;
      const record = JSON.parse(h.kv.store.get(key)!.value) as Record<string, unknown>;
      h.kv.store.set(key, { value: JSON.stringify({ ...record, counter }), expiresAt: null });
    }

    for (const [label, concurrent] of [["a later", 10], ["the same", 1]] as const) {
      it(`is never written backwards: ${label} counter recorded meanwhile wins and this request gets stale_counter`, async () => {
        const h = makeHarness({ rootCaPem: chain.root.pem });
        const device = await attestDevice(h);
        let reads = 0;
        h.kv.onGet = (key) => {
          // 1st read: the assertion check; 2nd: the re-read just before the write.
          if (key === `key:${device.keyIdB64}` && ++reads === 2) setCounter(h, device.keyIdB64, concurrent);
        };
        const r = await device.send("/v1beta/models/x:generateContent", "{}");
        assert.deepEqual([r.status, await r.json()], [401, { error: "stale_counter" }]);
        assert.equal(await storedCounter(h, device.keyIdB64), concurrent);
        assert.equal(h.calls.length, 0);
      });
    }

    it("re-reads before the retry write too", async () => {
      let bump: () => void = () => {};
      const h = makeHarness({ rootCaPem: chain.root.pem, sleep: async () => bump() });
      const device = await attestDevice(h);
      bump = () => setCounter(h, device.keyIdB64, 7); // another request lands during the 1.1 s pause
      let failures = 0;
      h.kv.failPut = (key) => key === `key:${device.keyIdB64}` && failures++ === 0;
      const r = await device.send("/v1beta/models/x:generateContent", "{}");
      assert.deepEqual([r.status, await r.json()], [401, { error: "stale_counter" }]);
      assert.equal(await storedCounter(h, device.keyIdB64), 7);
    });

    it("advances normally after a single failed write", async () => {
      const h = makeHarness({ rootCaPem: chain.root.pem });
      const device = await attestDevice(h);
      let failures = 0;
      h.kv.failPut = (key) => key === `key:${device.keyIdB64}` && failures++ === 0;
      assert.equal((await device.send("/v1beta/models/x:generateContent", "{}")).status, 200);
      assert.equal(await storedCounter(h, device.keyIdB64), 1);
    });
  });

  describe("development token", () => {
    const devHeaders = { "x-dev-token": "dev-secret-token" };

    it("is accepted only when ALLOW_DEV_TOKEN is exactly \"true\" and the token matches", async () => {
      const on = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
      assert.equal((await on.request("/v1beta/models", { headers: devHeaders })).status, 200);

      for (const allow of ["false", "TRUE", "1", ""]) {
        const off = makeHarness({ env: { ALLOW_DEV_TOKEN: allow } });
        const r = await off.request("/v1beta/models", { headers: devHeaders });
        assert.deepEqual([r.status, await r.json()], [401, { error: "attestation_required" }], `ALLOW_DEV_TOKEN=${allow}`);
      }
      const wrong = await on.request("/v1beta/models", { headers: { "x-dev-token": "dev-secret-tokeN" } });
      assert.deepEqual([wrong.status, await wrong.json()], [401, { error: "attestation_required" }]);
    });

    it("is never accepted when SS_DEV_TOKEN is unset, even with an empty header", async () => {
      const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true", SS_DEV_TOKEN: "" } });
      const r = await h.request("/v1beta/models", { headers: { "x-dev-token": "" } });
      assert.equal(r.status, 401);
    });

    it("falls through to the Bearer assertion when the dev token is wrong", async () => {
      const h = makeHarness({ rootCaPem: chain.root.pem, env: { ALLOW_DEV_TOKEN: "true" } });
      const device = await attestDevice(h);
      const r = await device.send("/v1beta/models", "", { headers: { "x-dev-token": "wrong" } });
      assert.equal(r.status, 200);
    });
  });

  it("rate-limits per identity per UTC minute with 429 and Retry-After", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true", RATE_LIMIT_PER_MIN: "3" } });
    h.clock.now = START + 15_000; // 45 s left in the minute
    const send = () => h.request("/v1beta/models", { headers: { "x-dev-token": "dev-secret-token" } });
    for (let i = 0; i < 3; i++) assert.equal((await send()).status, 200);
    const limited = await send();
    assert.equal(limited.status, 429);
    assert.equal(limited.headers.get("retry-after"), "45");
    assert.deepEqual(await limited.json(), { error: "rate_limited" });
    assert.equal(h.kv.writes.find((w) => w.key.startsWith("rl:dev:"))?.expirationTtl, 120);
    h.clock.now = START + 60_000;
    assert.equal((await send()).status, 200);
  });

  it("rate-limits attested keys separately", async () => {
    // Limit 4: the two attestations (challenge + attest each) use up this IP's 4 unauthenticated requests.
    const h = makeHarness({ rootCaPem: chain.root.pem, env: { RATE_LIMIT_PER_MIN: "4" } });
    const a = await attestDevice(h);
    const b = await attestDevice(h);
    assert.equal((await h.request("/attest/challenge")).status, 429);
    for (let i = 0; i < 4; i++) assert.equal((await a.send("/v1beta/models")).status, 200);
    assert.equal((await a.send("/v1beta/models")).status, 429);
    assert.equal((await b.send("/v1beta/models")).status, 200);
  });
});

describe("Gemini proxy", () => {
  it("forwards the exact body bytes, path and query (minus key), adds the API key and strips credentials", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const device = await attestDevice(h);
    h.setResponder(() => new Response("data: {\"candidates\":[]}\n\n", { status: 200, headers: { "content-type": "text/event-stream", "set-cookie": "a=b", "x-upstream": "1" } }));
    // Unusual spacing, key order, unicode and number formats must survive byte for byte.
    const body = utf8('{ "generationConfig":{"temperature":0.70,"responseMimeType":"application/json"},\n "contents":[{"parts":[{"text":"行程 ✓ \\u00e9"}]}] }');
    const r = await device.send("/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse&key=CLIENTKEY&x=a%20b&KEY=keep", body, {
      headers: {
        "content-type": "application/json; charset=utf-8",
        cookie: "s=1",
        "x-dev-token": "nope",
        "x-goog-api-key": "client-supplied",
        "cf-connecting-ip": "198.51.100.1",
        "cf-ipcountry": "TW",
        "cf-ray": "8a1b2c3d4e5f-TPE",
        "cf-anything-new": "1",
        "x-forwarded-for": "198.51.100.1",
      },
    });
    assert.equal(r.status, 200);
    assert.equal(r.headers.get("content-type"), "text/event-stream");
    assert.equal(r.headers.get("set-cookie"), null);
    assert.equal(await r.text(), 'data: {"candidates":[]}\n\n');

    assert.equal(h.calls.length, 1);
    const call = h.calls[0]!;
    assert.equal(call.url, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse&x=a%20b&KEY=keep");
    assert.equal(call.method, "POST");
    assert.deepEqual(call.body, body);
    assert.deepEqual(await sha256(call.body!), await sha256(body));
    assert.equal(call.headers.get("x-goog-api-key"), "test-gemini-key");
    assert.equal(call.headers.get("content-type"), "application/json; charset=utf-8");
    for (const stripped of ["authorization", "x-dev-token", "cookie", "cf-connecting-ip", "cf-ipcountry", "cf-ray", "cf-anything-new", "x-forwarded-for"]) {
      assert.equal(call.headers.get(stripped), null, stripped);
    }
    call.headers.forEach((_, name) => assert.ok(!name.startsWith("cf-"), name));
  });

  it("returns upstream errors unchanged", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    h.setResponder(() => new Response('{"error":{"code":429}}', { status: 429, headers: { "content-type": "application/json; charset=UTF-8" } }));
    const r = await h.request("/v1beta/models/x:generateContent", { method: "POST", headers: { "x-dev-token": "dev-secret-token" }, body: "{}" });
    assert.equal(r.status, 429);
    assert.equal(r.headers.get("content-type"), "application/json; charset=UTF-8");
    assert.equal(await r.text(), '{"error":{"code":429}}');
  });

  it("forwards GET without a body and drops a lone key parameter", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    await h.request("/v1beta/models?key=abc", { headers: { "x-dev-token": "dev-secret-token" } });
    assert.equal(h.calls[0]!.url, "https://generativelanguage.googleapis.com/v1beta/models");
    assert.equal(h.calls[0]!.method, "GET");
    assert.equal(h.calls[0]!.body, null);
  });

  it("refuses to proxy without GEMINI_API_KEY", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true", GEMINI_API_KEY: "" } });
    const r = await h.request("/v1beta/models", { headers: { "x-dev-token": "dev-secret-token" } });
    assert.deepEqual([r.status, await r.json()], [500, { error: "server_misconfigured" }]);
    assert.equal(h.calls.length, 0);
  });

  it("returns 404 for unknown routes and 405 for wrong methods", async () => {
    const h = makeHarness();
    assert.deepEqual(await (await h.request("/v1/models")).json(), { error: "not_found" });
    assert.equal((await h.request("/attest", { method: "GET" })).status, 405);
  });
});

describe("POST /devices/push-to-start", () => {
  const DEV = { "x-dev-token": "dev-secret-token", "content-type": "application/json" };
  const DEVICE = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
  const TOKEN = "80b4c3a1".repeat(10);

  function event(overrides: Record<string, unknown> = {}) {
    return {
      attributesJSON: '{"eventID":"ev1"}',
      contentStateJSON: '{"countdownFrom":782208000,"headline":"Standup","isInProgress":false}',
      eventID: "ev1",
      eventStart: "2026-10-15T09:00:00Z",
      leadTime: 30,
      title: "Standup",
      triggerAt: "2026-10-15T08:30:00Z",
      ...overrides,
    };
  }

  function register(h: Harness, body: unknown, headers: Record<string, string> = DEV) {
    return h.request("/devices/push-to-start", { method: "POST", headers, body: JSON.stringify(body) });
  }

  function stored(h: Harness): Promise<Record<string, unknown>> {
    return h.kv.get(`p2s:${DEVICE}`).then((raw) => JSON.parse(raw!) as Record<string, unknown>);
  }

  it("stores only the contract fields with a 3-day TTL and indexes each event by its eventID hash", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    const r = await register(h, { deviceID: DEVICE, token: TOKEN, events: [event({ notes: "secret", location: "home" }), event({ eventID: "A:B:C", triggerAt: "2026-10-15T09:05:30Z" })], extra: 1 });
    assert.deepEqual(await r.json(), { ok: true, events: 2 });
    const registration = await stored(h);
    assert.deepEqual(Object.keys(registration).sort(), ["appId", "events", "keyId", "token", "updatedAt"]);
    assert.equal(registration.keyId, "dev");
    assert.equal(registration.appId, null);
    assert.equal(registration.token, TOKEN);
    const events = registration.events as Record<string, unknown>[];
    assert.deepEqual(Object.keys(events[0]!).sort(), ["attributesJSON", "contentStateJSON", "eventID", "eventStart", "leadTime", "title", "triggerAt"]);
    assert.equal(events[1]!.eventID, "A:B:C", "the real eventID stays in the registration");
    assert.equal(h.kv.writes.find((w) => w.key === `p2s:${DEVICE}`)?.expirationTtl, 3 * 86400);
    const ev1 = await eventHash("ev1");
    assert.equal(ev1, hex(await sha256(utf8("ev1"))));
    assert.deepEqual(h.kv.keysWithPrefix("due:"), [`due:202610150830:${DEVICE}:${ev1}`, `due:202610150905:${DEVICE}:${await eventHash("A:B:C")}`]);
    // TTL until triggerAt + 1 h: 08:30 + 1 h − 08:00 = 5400 s.
    assert.equal(h.kv.writes.find((w) => w.key === `due:202610150830:${DEVICE}:${ev1}`)?.expirationTtl, 5400);
  });

  it("treats a missing token (Swift omits nil) as null and accepts an empty event list", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    assert.deepEqual(await (await register(h, { deviceID: DEVICE, events: [event()] })).json(), { ok: true, events: 1 });
    assert.equal((await stored(h)).token, null);
    assert.deepEqual(await (await register(h, { deviceID: DEVICE, token: null, events: [] })).json(), { ok: true, events: 0 });
  });

  it("rejects body-level problems with 400 invalid_registration", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    const base = { deviceID: DEVICE, token: TOKEN, events: [event()] };
    const cases: [string, unknown][] = [
      ["not an object", [base]],
      ["deviceID chars", { ...base, deviceID: "dev/../x" }],
      ["deviceID length", { ...base, deviceID: "a".repeat(65) }],
      ["token not hex", { ...base, token: "zz" }],
      ["token too long", { ...base, token: "a".repeat(201) }],
      ["too many events", { ...base, events: Array.from({ length: 51 }, (_, i) => event({ eventID: `e${i}` })) }],
      ["events missing", { deviceID: DEVICE, token: TOKEN }],
    ];
    for (const [name, body] of cases) {
      const r = await register(h, body);
      assert.deepEqual([r.status, await r.json()], [400, { error: "invalid_registration" }], name);
    }
    assert.equal(h.kv.keysWithPrefix("p2s:").length, 0);
  });

  it("skips an invalid event instead of rejecting the batch, and shortens long titles", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    const bad: [string, Record<string, unknown>][] = [
      ["eventID too long", { eventID: "x".repeat(1025) }],
      ["eventID empty", { eventID: "" }],
      ["eventID control char", { eventID: "a\u0007b" }],
      ["title not a string", { title: 5 }],
      ["attributes not JSON", { attributesJSON: "{" }],
      ["attributes not an object", { attributesJSON: "[1]" }],
      ["content-state too big", { contentStateJSON: JSON.stringify({ s: "x".repeat(4100) }) }],
      ["triggerAt too old", { triggerAt: "2026-10-15T06:59:59Z" }],
      ["triggerAt too far", { triggerAt: "2026-10-17T09:00:01Z" }],
      ["triggerAt not ISO", { triggerAt: "Oct 15 2026" }],
      ["eventStart missing", { eventStart: undefined }],
      ["leadTime fractional", { leadTime: 2.5 }],
    ];
    const longTitle = "📅".repeat(150) + "é".repeat(100); // 250 code points
    const events = [
      event({ eventID: "good-1", title: longTitle }),
      ...bad.map(([, o], i) => event({ eventID: `bad-${i}`, ...o })),
      "not an object",
      event({ eventID: "y".repeat(1024), triggerAt: "2026-10-15T07:00:00Z" }), // 1024-byte ID, window boundary
    ];
    const r = await register(h, { deviceID: DEVICE, token: TOKEN, events });
    assert.deepEqual([r.status, await r.json()], [200, { ok: true, events: 2 }]);
    const kept = (await stored(h)).events as { eventID: string; title: string }[];
    assert.deepEqual(kept.map((e) => e.eventID.slice(0, 6)), ["good-1", "yyyyyy"]);
    assert.equal(Array.from(kept[0]!.title).length, 200);
    assert.equal(kept[0]!.title, Array.from(longTitle).slice(0, 200).join(""));
    assert.equal(h.kv.keysWithPrefix("due:").length, 2);
  });

  it("whole-replaces the registration while sent markers survive the overwrite", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    await register(h, { deviceID: DEVICE, token: TOKEN, events: [event(), event({ eventID: "ev2", title: "Lunch" })] });
    const marker = `sent:${DEVICE}:${await eventHash("ev1")}:${Date.parse("2026-10-15T08:30:00Z") / 1000}`;
    await h.kv.put(marker, "1", { expirationTtl: 3 * 86400 }); // as the cron would after a send

    const writesBefore = h.kv.writes.length;
    await register(h, { deviceID: DEVICE, token: TOKEN, events: [event()] });
    assert.deepEqual(((await stored(h)).events as { eventID: string }[]).map((e) => e.eventID), ["ev1"]);
    assert.equal(await h.kv.get(marker), "1");
    // Unchanged (eventID, triggerAt) pairs are already indexed: only the registration itself is rewritten.
    assert.deepEqual(
      h.kv.writes.slice(writesBefore).map((w) => w.key).filter((k) => !k.startsWith("rl:")),
      [`p2s:${DEVICE}`],
    );
  });

  it("lets another attested key of the same app take a deviceID over (key rotation / restore)", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const before = await attestDevice(h);
    const after = await attestDevice(h); // the same app after its App Attest key was replaced
    const body = JSON.stringify({ deviceID: DEVICE, token: TOKEN, events: [event()] });
    assert.equal((await before.send("/devices/push-to-start", body)).status, 200);
    assert.equal((await stored(h)).keyId, before.keyIdB64);

    const logs: string[] = [];
    const originalLog = console.log;
    console.log = (line: string) => logs.push(line);
    let r: Response;
    try {
      r = await after.send("/devices/push-to-start", body);
    } finally {
      console.log = originalLog;
    }
    assert.deepEqual([r.status, await r.json()], [200, { ok: true, events: 1 }]);
    const registration = await stored(h);
    assert.equal(registration.keyId, after.keyIdB64);
    assert.equal(registration.appId, `${TEAM_ID}.${BUNDLE_ID}`);
    assert.ok(logs.some((l) => JSON.parse(l).event === "registration_rebound"), "takeover is logged");
    assert.equal((await before.send("/devices/push-to-start", body)).status, 200, "and back again");
  });

  it("keeps 403 forbidden between the development identity and attested ones, and across apps", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem, env: { ALLOW_DEV_TOKEN: "true" } });
    const app = await attestDevice(h);
    const otherApp = await attestDevice(h, "com.smartschedule.app.notification-content");
    const body = JSON.stringify({ deviceID: DEVICE, token: TOKEN, events: [event()] });
    assert.equal((await app.send("/devices/push-to-start", body)).status, 200);

    let r = await register(h, { deviceID: DEVICE, token: TOKEN, events: [] });
    assert.deepEqual([r.status, await r.json()], [403, { error: "forbidden" }], "dev over attested");
    r = await otherApp.send("/devices/push-to-start", body);
    assert.deepEqual([r.status, await r.json()], [403, { error: "forbidden" }], "another appId");

    const devOwned = "DEV-OWNED-1";
    assert.equal((await register(h, { deviceID: devOwned, token: TOKEN, events: [] })).status, 200);
    r = await app.send("/devices/push-to-start", JSON.stringify({ deviceID: devOwned, token: TOKEN, events: [] }));
    assert.deepEqual([r.status, await r.json()], [403, { error: "forbidden" }], "attested over dev");
  });

  it("writes a duplicated event's index once and answers 503 server_busy when KV refuses a write", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    assert.deepEqual(await (await register(h, { deviceID: DEVICE, token: TOKEN, events: [event(), event()] })).json(), { ok: true, events: 2 });
    assert.equal(h.kv.writes.filter((w) => w.key.startsWith("due:")).length, 1);

    h.kv.failPut = (key) => key.startsWith("p2s:");
    const r = await register(h, { deviceID: DEVICE, token: TOKEN, events: [] });
    assert.deepEqual([r.status, await r.json()], [503, { error: "server_busy" }]);
  });

  it("requires an assertion or the dev token (a session token is refused)", async () => {
    const h = makeHarness();
    let r = await h.request("/devices/push-to-start", { method: "POST", body: "{}" });
    assert.deepEqual([r.status, await r.json()], [401, { error: "attestation_required" }]);
    r = await h.request("/devices/push-to-start", { method: "POST", body: "{}", headers: { authorization: `Session ${"A".repeat(43)}` } });
    assert.deepEqual([r.status, await r.json()], [401, { error: "attestation_required" }]);
  });
});

describe("POST /session and Session tokens", () => {
  async function issue(h: Harness, device: Device): Promise<{ token: string; expiresAt: string }> {
    const r = await device.send("/session", "{}");
    assert.equal(r.status, 200, await r.clone().text());
    return (await r.json()) as { token: string; expiresAt: string };
  }

  function sessionKey(token: string): Promise<string> {
    return sha256(utf8(token)).then((h) => `sess:${hex(h)}`);
  }

  it("issues a 32-byte base64url token to an attested key and stores only its hash", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const device = await attestDevice(h);
    const { token, expiresAt } = await issue(h, device);
    assert.match(token, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(expiresAt, "2026-10-22T08:00:00Z");
    const key = await sessionKey(token);
    assert.deepEqual(JSON.parse((await h.kv.get(key))!), { id: device.keyIdB64, appId: `${TEAM_ID}.${BUNDLE_ID}`, expiresAt });
    assert.equal(h.kv.writes.find((w) => w.key === key)?.expirationTtl, 604800);
    assert.equal(h.kv.keysWithPrefix("sess:").length, 1);
    assert.ok(!h.kv.writes.some((w) => w.key.includes(token) || w.value.includes(token)), "the token itself is never stored");
  });

  it("issues to the dev identity with appId null and honours SESSION_TTL_SECONDS", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true", SESSION_TTL_SECONDS: "3600" } });
    const r = await h.request("/session", { method: "POST", headers: { "x-dev-token": "dev-secret-token" }, body: "{}" });
    const { token, expiresAt } = (await r.json()) as { token: string; expiresAt: string };
    assert.equal(expiresAt, "2026-10-15T09:00:00Z");
    const key = await sessionKey(token);
    assert.deepEqual(JSON.parse((await h.kv.get(key))!), { id: "dev", appId: null, expiresAt });
    assert.equal(h.kv.writes.find((w) => w.key === key)?.expirationTtl, 3600);
  });

  it("validates the /session body: a JSON object of at most 1 KB", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    const dev = { "x-dev-token": "dev-secret-token" };
    assert.equal((await h.request("/session", { method: "POST", headers: dev, body: '{"bundle":"x"}' })).status, 200);
    let r = await h.request("/session", { method: "POST", headers: dev, body: "[]" });
    assert.deepEqual([r.status, await r.json()], [400, { error: "invalid_request" }]);
    r = await h.request("/session", { method: "POST", headers: dev, body: JSON.stringify({ pad: "x".repeat(1100) }) });
    assert.deepEqual([r.status, await r.json()], [413, { error: "payload_too_large" }]);
    assert.equal((await h.request("/session", { headers: dev })).status, 405);
  });

  it("authenticates /v1beta/*: forwarded with the API key and without the Authorization header", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const device = await attestDevice(h);
    const { token } = await issue(h, device);
    const body = utf8('{"contents":[{"parts":[{"text":"from the extension"}]}]}');
    const r = await h.request("/v1beta/models/gemini-2.5-flash:generateContent", {
      method: "POST",
      headers: { authorization: `Session ${token}`, "content-type": "application/json" },
      body,
    });
    assert.equal(r.status, 200);
    const call = h.calls.at(-1)!;
    assert.equal(call.url, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent");
    assert.deepEqual(call.body, body);
    assert.equal(call.headers.get("x-goog-api-key"), "test-gemini-key");
    assert.equal(call.headers.get("authorization"), null);
    assert.equal((JSON.parse((await h.kv.get(`key:${device.keyIdB64}`))!) as { counter: number }).counter, 1, "no assertion counter involved");
  });

  it("is refused on /session and /devices/push-to-start, and means nothing to /attest", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem });
    const device = await attestDevice(h);
    const { token } = await issue(h, device);
    const headers = { authorization: `Session ${token}` };
    for (const path of ["/session", "/devices/push-to-start"]) {
      const r = await h.request(path, { method: "POST", headers, body: "{}" });
      assert.deepEqual([r.status, await r.json()], [401, { error: "attestation_required" }], path);
    }
    const r = await h.request("/attest", { method: "POST", headers, body: "{}" });
    assert.deepEqual([r.status, await r.json()], [400, { error: "invalid_request" }]);
  });

  it("rejects unknown, malformed and expired tokens with invalid_session", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem, env: { SESSION_TTL_SECONDS: "600" } });
    const device = await attestDevice(h);
    const { token } = await issue(h, device);
    const use = (t: string) => h.request("/v1beta/models", { headers: { authorization: `Session ${t}` } });
    assert.equal((await use(token)).status, 200);
    for (const bad of [b64encode(crypto.getRandomValues(new Uint8Array(32))).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_"), "short", "x".repeat(44)]) {
      const r = await use(bad);
      assert.deepEqual([r.status, await r.json()], [401, { error: "invalid_session" }], bad);
    }
    h.clock.now += 600_000;
    const expired = await use(token);
    assert.deepEqual([expired.status, await expired.json()], [401, { error: "invalid_session" }]);

    // A record KV has not purged yet is still refused once its expiresAt has passed.
    const stale = "S".repeat(43);
    await h.kv.put(await sessionKey(stale), JSON.stringify({ id: device.keyIdB64, appId: `${TEAM_ID}.${BUNDLE_ID}`, expiresAt: "2026-10-15T08:00:00Z" }), { expirationTtl: 3600 });
    const lagging = await use(stale);
    assert.deepEqual([lagging.status, await lagging.json()], [401, { error: "invalid_session" }]);
  });

  it("shares the per-minute rate limit with the key that requested it", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem, env: { RATE_LIMIT_PER_MIN: "3" } });
    const device = await attestDevice(h);
    const { token } = await issue(h, device); // 1
    const use = () => h.request("/v1beta/models", { headers: { authorization: `Session ${token}` } });
    assert.equal((await use()).status, 200); // 2
    assert.equal((await use()).status, 200); // 3
    const limited = await use();
    assert.deepEqual([limited.status, await limited.json()], [429, { error: "rate_limited" }]);
    assert.equal((await device.send("/v1beta/models")).status, 429, "the key's own requests share the bucket");
    h.clock.now += 60_000;
    assert.equal((await use()).status, 200);
  });

  it("stops honouring dev sessions once ALLOW_DEV_TOKEN is no longer \"true\"", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    const r = await h.request("/session", { method: "POST", headers: { "x-dev-token": "dev-secret-token" }, body: "{}" });
    const { token } = (await r.json()) as { token: string };
    assert.equal((await h.request("/v1beta/models", { headers: { authorization: `Session ${token}` } })).status, 200);
    h.env.ALLOW_DEV_TOKEN = "false";
    const refused = await h.request("/v1beta/models", { headers: { authorization: `Session ${token}` } });
    assert.deepEqual([refused.status, await refused.json()], [401, { error: "invalid_session" }]);
  });
});
