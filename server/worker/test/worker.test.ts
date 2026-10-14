import assert from "node:assert/strict";
import { before, describe, it } from "node:test";
import { b64decode, b64encode, sha256, utf8 } from "../src/encoding.ts";
import type { Chain } from "./helpers/app-attest.ts";
import { BUNDLE_ID, TEAM_ID, bearer, makeAssertion, makeAttestation, makeChain } from "./helpers/app-attest.ts";
import type { Harness } from "./helpers/harness.ts";
import { START, jsonOf, makeHarness } from "./helpers/harness.ts";
import { generateEcKeyPair } from "./helpers/webcrypto.ts";

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
      headers: { "content-type": "application/json; charset=utf-8", cookie: "s=1", "x-dev-token": "nope", "x-goog-api-key": "client-supplied", "cf-connecting-ip": "198.51.100.1" },
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
    for (const stripped of ["authorization", "x-dev-token", "cookie", "cf-connecting-ip"]) assert.equal(call.headers.get(stripped), null, stripped);
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

  it("stores only the contract fields with a 3-day TTL and indexes each event", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    const r = await register(h, { deviceID: DEVICE, token: TOKEN, events: [event({ notes: "secret", location: "home" }), event({ eventID: "A:B:C", triggerAt: "2026-10-15T09:05:30Z" })], extra: 1 });
    assert.deepEqual(await r.json(), { ok: true, events: 2 });
    const stored = JSON.parse((await h.kv.get(`p2s:${DEVICE}`))!) as Record<string, unknown>;
    assert.deepEqual(Object.keys(stored).sort(), ["events", "keyId", "token", "updatedAt"]);
    assert.equal(stored.keyId, "dev");
    assert.equal(stored.token, TOKEN);
    const events = stored.events as Record<string, unknown>[];
    assert.deepEqual(Object.keys(events[0]!).sort(), ["attributesJSON", "contentStateJSON", "eventID", "eventStart", "leadTime", "title", "triggerAt"]);
    assert.equal(h.kv.writes.find((w) => w.key === `p2s:${DEVICE}`)?.expirationTtl, 3 * 86400);
    assert.deepEqual(h.kv.keysWithPrefix("due:"), [`due:202610150830:${DEVICE}:ev1`, `due:202610150905:${DEVICE}:A:B:C`]);
    // TTL until triggerAt + 1 h: 08:30 + 1 h − 08:00 = 5400 s.
    assert.equal(h.kv.writes.find((w) => w.key === `due:202610150830:${DEVICE}:ev1`)?.expirationTtl, 5400);
  });

  it("treats a missing token (Swift omits nil) as null and accepts an empty event list", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    assert.deepEqual(await (await register(h, { deviceID: DEVICE, events: [event()] })).json(), { ok: true, events: 1 });
    assert.equal((JSON.parse((await h.kv.get(`p2s:${DEVICE}`))!) as { token: unknown }).token, null);
    assert.deepEqual(await (await register(h, { deviceID: DEVICE, token: null, events: [] })).json(), { ok: true, events: 0 });
  });

  it("rejects invalid registrations with 400 invalid_registration", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    const base = { deviceID: DEVICE, token: TOKEN, events: [event()] };
    const cases: [string, unknown][] = [
      ["not an object", [base]],
      ["deviceID chars", { ...base, deviceID: "dev/../x" }],
      ["deviceID length", { ...base, deviceID: "a".repeat(65) }],
      ["token not hex", { ...base, token: "zz" }],
      ["token too long", { ...base, token: "a".repeat(201) }],
      ["too many events", { ...base, events: Array.from({ length: 51 }, (_, i) => event({ eventID: `e${i}` })) }],
      ["title too long", { ...base, events: [event({ title: "x".repeat(201) })] }],
      ["attributes not JSON", { ...base, events: [event({ attributesJSON: "{" })] }],
      ["attributes not an object", { ...base, events: [event({ attributesJSON: "[1]" })] }],
      ["content-state too big", { ...base, events: [event({ contentStateJSON: JSON.stringify({ s: "x".repeat(4100) }) })] }],
      ["triggerAt too old", { ...base, events: [event({ triggerAt: "2026-10-15T06:59:59Z" })] }],
      ["triggerAt too far", { ...base, events: [event({ triggerAt: "2026-10-17T09:00:01Z" })] }],
      ["triggerAt not ISO", { ...base, events: [event({ triggerAt: "Oct 15 2026" })] }],
      ["eventStart missing", { ...base, events: [event({ eventStart: undefined })] }],
      ["leadTime fractional", { ...base, events: [event({ leadTime: 2.5 })] }],
      ["events missing", { deviceID: DEVICE, token: TOKEN }],
    ];
    for (const [name, body] of cases) {
      const r = await register(h, body);
      assert.deepEqual([r.status, await r.json()], [400, { error: "invalid_registration" }], name);
    }
    const boundary = await register(h, { ...base, events: [event({ title: "é".repeat(200), triggerAt: "2026-10-15T07:00:00Z" })] });
    assert.equal(boundary.status, 200);
    assert.equal(h.kv.keysWithPrefix("p2s:").length, 1);
  });

  it("whole-replaces the registration while sent markers survive the overwrite", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    await register(h, { deviceID: DEVICE, token: TOKEN, events: [event(), event({ eventID: "ev2", title: "Lunch" })] });
    const marker = `sent:${DEVICE}:ev1:${Date.parse("2026-10-15T08:30:00Z") / 1000}`;
    await h.kv.put(marker, "1", { expirationTtl: 3 * 86400 }); // as the cron would after a send

    const writesBefore = h.kv.writes.length;
    await register(h, { deviceID: DEVICE, token: TOKEN, events: [event()] });
    const stored = JSON.parse((await h.kv.get(`p2s:${DEVICE}`))!) as { events: { eventID: string }[] };
    assert.deepEqual(stored.events.map((e) => e.eventID), ["ev1"]);
    assert.equal(await h.kv.get(marker), "1");
    // Unchanged (eventID, triggerAt) pairs are already indexed: only the registration itself is rewritten.
    assert.deepEqual(
      h.kv.writes.slice(writesBefore).map((w) => w.key).filter((k) => !k.startsWith("rl:")),
      [`p2s:${DEVICE}`],
    );
  });

  it("binds a deviceID to its first identity: another identity gets 403 forbidden", async () => {
    const h = makeHarness({ rootCaPem: chain.root.pem, env: { ALLOW_DEV_TOKEN: "true" } });
    const owner = await attestDevice(h);
    const other = await attestDevice(h);
    const body = JSON.stringify({ deviceID: DEVICE, token: TOKEN, events: [event()] });
    assert.equal((await owner.send("/devices/push-to-start", body)).status, 200);
    assert.equal((JSON.parse((await h.kv.get(`p2s:${DEVICE}`))!) as { keyId: string }).keyId, owner.keyIdB64);
    const r = await other.send("/devices/push-to-start", body);
    assert.deepEqual([r.status, await r.json()], [403, { error: "forbidden" }]);
    const dev = await register(h, { deviceID: DEVICE, token: TOKEN, events: [] });
    assert.equal(dev.status, 403);
    assert.equal((await owner.send("/devices/push-to-start", body)).status, 200);
  });

  it("writes a duplicated event's index once and answers 503 server_busy when KV refuses a write", async () => {
    const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true" } });
    assert.deepEqual(await (await register(h, { deviceID: DEVICE, token: TOKEN, events: [event(), event()] })).json(), { ok: true, events: 2 });
    assert.equal(h.kv.writes.filter((w) => w.key.startsWith("due:")).length, 1);

    h.kv.failPut = (key) => key.startsWith("p2s:");
    const r = await register(h, { deviceID: DEVICE, token: TOKEN, events: [] });
    assert.deepEqual([r.status, await r.json()], [503, { error: "server_busy" }]);
  });

  it("requires authentication", async () => {
    const h = makeHarness();
    const r = await h.request("/devices/push-to-start", { method: "POST", body: "{}" });
    assert.deepEqual([r.status, await r.json()], [401, { error: "attestation_required" }]);
  });
});
