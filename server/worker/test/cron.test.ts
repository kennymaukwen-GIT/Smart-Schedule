import assert from "node:assert/strict";
import { before, beforeEach, describe, it } from "node:test";
import { b64encode, b64urlDecode, utf8 } from "../src/encoding.ts";
import { resetJwtCacheForTests } from "../src/jwt.ts";
import type { Env } from "../src/env.ts";
import type { FetchCall, Harness } from "./helpers/harness.ts";
import { makeHarness } from "./helpers/harness.ts";
import { exportKeyBytes, generateEcKeyPair } from "./helpers/webcrypto.ts";

const DEVICE = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
const TOKEN = "80b4c3a1".repeat(10);
const DEV = { "x-dev-token": "dev-secret-token", "content-type": "application/json" };
const at = (iso: string) => Date.parse(iso);

let p8: string;
let apnsPublicKey: CryptoKey;

before(async () => {
  const keys = await generateEcKeyPair("P-256");
  const pkcs8 = await exportKeyBytes("pkcs8", keys.privateKey);
  p8 = `-----BEGIN PRIVATE KEY-----\n${b64encode(pkcs8).match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
  apnsPublicKey = keys.publicKey;
});

beforeEach(() => resetJwtCacheForTests());

function event(overrides: Record<string, unknown> = {}) {
  return {
    attributesJSON: '{"eventID":"ev1"}',
    // Number formats a re-encoder would change (782208000.0 → 782208000, 1.5E3 → 1500) must survive verbatim.
    contentStateJSON: '{"countdownFrom":782208000.0,"countdownTarget":1.5E3,"headline":"Standup","isInProgress":false,"days":[]}',
    eventID: "ev1",
    eventStart: "2026-10-15T09:00:00Z",
    leadTime: 30,
    title: "Standup “daily”",
    triggerAt: "2026-10-15T08:30:00Z",
    ...overrides,
  };
}

function setup(env: Partial<Env> = {}): Harness {
  const h = makeHarness({ env: { ALLOW_DEV_TOKEN: "true", APNS_PRIVATE_KEY: p8, ...env } });
  h.setResponder(() => new Response(null, { status: 200, headers: { "apns-id": "11111111-2222-3333-4444-555555555555" } }));
  return h;
}

async function register(h: Harness, events: unknown[], token: string | null = TOKEN) {
  const r = await h.request("/devices/push-to-start", { method: "POST", headers: DEV, body: JSON.stringify({ deviceID: DEVICE, events, token }) });
  assert.equal(r.status, 200, await r.clone().text());
}

async function cronAt(h: Harness, iso: string): Promise<FetchCall[]> {
  h.clock.now = at(iso);
  const before = h.calls.length;
  await h.runCron();
  return h.calls.slice(before);
}

describe("cron push-to-start", () => {
  it("sends once when triggerAt is within 60 s and never resends the same eventID + triggerAt", async () => {
    const h = setup();
    await register(h, [event()]);
    assert.equal((await cronAt(h, "2026-10-15T08:00:00Z")).length, 0);
    assert.equal((await cronAt(h, "2026-10-15T08:28:30Z")).length, 0, "90 s early");
    const sent = await cronAt(h, "2026-10-15T08:29:10Z");
    assert.equal(sent.length, 1);
    const marker = `sent:${DEVICE}:ev1:${at("2026-10-15T08:30:00Z") / 1000}`;
    assert.equal(await h.kv.get(marker), "1");
    assert.equal(h.kv.writes.find((w) => w.key === marker)?.expirationTtl, 3 * 86400);
    for (const t of ["2026-10-15T08:30:10Z", "2026-10-15T08:31:10Z", "2026-10-15T08:32:10Z"]) {
      assert.equal((await cronAt(h, t)).length, 0, t);
    }
    // A registration overwrite (same event) does not re-arm it.
    await register(h, [event()]);
    assert.equal((await cronAt(h, "2026-10-15T08:30:40Z")).length, 0);
  });

  it("builds the APNs request: host, path, headers, ES256 JWT and payload", async () => {
    const h = setup();
    await register(h, [event()]);
    const [call] = await cronAt(h, "2026-10-15T08:29:30Z");
    assert.ok(call);
    assert.equal(call.url, `https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
    assert.equal(call.method, "POST");
    assert.equal(call.headers.get("apns-push-type"), "liveactivity");
    assert.equal(call.headers.get("apns-topic"), "com.smartschedule.app.push-type.liveactivity");
    assert.equal(call.headers.get("apns-priority"), "10");
    assert.equal(call.headers.get("content-type"), "application/json");

    const authorization = call.headers.get("authorization")!;
    assert.match(authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    const [header, claims, signature] = authorization.slice("bearer ".length).split(".") as [string, string, string];
    assert.deepEqual(JSON.parse(new TextDecoder().decode(b64urlDecode(header)!)), { alg: "ES256", kid: "KEYID12345" });
    assert.deepEqual(JSON.parse(new TextDecoder().decode(b64urlDecode(claims)!)), { iss: "ABCDE12345", iat: at("2026-10-15T08:29:30Z") / 1000 });
    assert.ok(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, apnsPublicKey, b64urlDecode(signature)!, utf8(`${header}.${claims}`)));

    const raw = new TextDecoder().decode(call.body!);
    assert.ok(raw.includes(`"content-state":${event().contentStateJSON}`), "content-state spliced verbatim");
    assert.ok(raw.length <= 4096);
    assert.deepEqual(JSON.parse(raw), {
      aps: {
        timestamp: at("2026-10-15T08:29:30Z") / 1000,
        event: "start",
        "attributes-type": "ScheduleActivityAttributes",
        attributes: { eventID: "ev1" },
        "content-state": JSON.parse(event().contentStateJSON),
        "stale-date": at("2026-10-15T09:00:00Z") / 1000,
        alert: { title: "Standup “daily”", body: { "loc-key": "Starts in %@ min", "loc-args": ["30"] } },
      },
    });
    assert.deepEqual(Object.keys(JSON.parse(raw).aps), ["timestamp", "event", "attributes-type", "attributes", "content-state", "stale-date", "alert"]);
  });

  it("uses the production host and the configured topic", async () => {
    const h = setup({ APNS_ENV: "production", APNS_BUNDLE_ID: "com.example.bundle" });
    await register(h, [event()]);
    const [call] = await cronAt(h, "2026-10-15T08:29:30Z");
    assert.equal(call?.url, `https://api.push.apple.com/3/device/${TOKEN}`);
    assert.equal(call?.headers.get("apns-topic"), "com.example.bundle.push-type.liveactivity");
  });

  it("skips an event deleted by a later registration", async () => {
    const h = setup();
    const ev2 = event({ eventID: "ev2", triggerAt: "2026-10-15T08:30:20Z", attributesJSON: '{"eventID":"ev2"}' });
    await register(h, [event(), ev2]);
    await register(h, [ev2]);
    const calls = await cronAt(h, "2026-10-15T08:29:30Z");
    assert.equal(calls.length, 1);
    assert.equal(JSON.parse(new TextDecoder().decode(calls[0]!.body!)).aps.attributes.eventID, "ev2");
    assert.equal(await h.kv.get(`sent:${DEVICE}:ev1:${at("2026-10-15T08:30:00Z") / 1000}`), null);
    assert.equal(await h.kv.get(`sent:${DEVICE}:ev2:${at("2026-10-15T08:30:20Z") / 1000}`), "1");
  });

  it("skips a moved event at its old time and sends it once at the new time", async () => {
    const h = setup();
    await register(h, [event()]);
    await register(h, [event({ triggerAt: "2026-10-15T09:30:00Z", eventStart: "2026-10-15T10:00:00Z" })]);
    assert.equal((await cronAt(h, "2026-10-15T08:29:30Z")).length, 0);
    assert.equal((await cronAt(h, "2026-10-15T08:30:30Z")).length, 0);
    assert.equal((await cronAt(h, "2026-10-15T09:29:30Z")).length, 1);
    assert.equal((await cronAt(h, "2026-10-15T09:30:30Z")).length, 0);
  });

  it("sends each occurrence of a recurring event (same eventID, different triggerAt)", async () => {
    const h = setup();
    await register(h, [event(), event({ triggerAt: "2026-10-16T08:30:00Z", eventStart: "2026-10-16T09:00:00Z" })]);
    assert.equal((await cronAt(h, "2026-10-15T08:29:30Z")).length, 1);
    assert.equal((await cronAt(h, "2026-10-16T08:29:30Z")).length, 1);
    assert.equal((await cronAt(h, "2026-10-16T08:30:30Z")).length, 0);
  });

  it("nulls the token on 410 Unregistered and stops sending to it", async () => {
    const h = setup();
    await register(h, [event(), event({ eventID: "ev2" })]);
    h.setResponder(() => Response.json({ reason: "Unregistered", timestamp: 1 }, { status: 410 }));
    const calls = await cronAt(h, "2026-10-15T08:29:30Z");
    assert.equal(calls.length, 1, "the second event is not attempted with the dead token");
    const stored = JSON.parse((await h.kv.get(`p2s:${DEVICE}`))!) as Record<string, unknown>;
    assert.equal(stored.token, null);
    assert.equal(stored.tokenInvalidAt, new Date(at("2026-10-15T08:29:30Z")).toISOString());
    assert.equal((stored.events as unknown[]).length, 2);
    assert.equal(h.kv.keysWithPrefix("sent:").length, 0);
    assert.equal((await cronAt(h, "2026-10-15T08:30:30Z")).length, 0);
  });

  it("nulls the token on 400 BadDeviceToken but not on other 400 reasons", async () => {
    const h = setup();
    await register(h, [event()]);
    h.setResponder(() => Response.json({ reason: "BadTopic" }, { status: 400 }));
    await cronAt(h, "2026-10-15T08:29:30Z");
    assert.equal((JSON.parse((await h.kv.get(`p2s:${DEVICE}`))!) as { token: string }).token, TOKEN);
    h.setResponder(() => Response.json({ reason: "BadDeviceToken" }, { status: 400 }));
    await cronAt(h, "2026-10-15T08:30:30Z");
    assert.equal((JSON.parse((await h.kv.get(`p2s:${DEVICE}`))!) as { token: string | null }).token, null);
  });

  it("does not null a token the device has replaced meanwhile", async () => {
    const h = setup();
    await register(h, [event()]);
    const fresh = "ab".repeat(40);
    h.setResponder(async () => {
      await register(h, [event()], fresh); // re-registered while the push was in flight
      return Response.json({ reason: "Unregistered" }, { status: 410 });
    });
    await cronAt(h, "2026-10-15T08:29:30Z");
    assert.equal((JSON.parse((await h.kv.get(`p2s:${DEVICE}`))!) as { token: string }).token, fresh);
  });

  it("retries other failures every minute until the window passes", async () => {
    const h = setup();
    await register(h, [event()]);
    h.setResponder(() => Response.json({ reason: "InternalServerError" }, { status: 500 }));
    const attempts = [];
    for (const t of ["2026-10-15T08:29:30Z", "2026-10-15T08:30:30Z", "2026-10-15T08:31:30Z", "2026-10-15T08:32:30Z", "2026-10-15T08:33:30Z"]) {
      attempts.push((await cronAt(h, t)).length);
    }
    assert.deepEqual(attempts, [1, 1, 1, 1, 0], "the 08:30 minute leaves the [now − 2, now + 1] window at 08:33");
    assert.equal(h.kv.keysWithPrefix("sent:").length, 0);
  });

  it("succeeds on a retry after a transient failure and then stops", async () => {
    const h = setup();
    await register(h, [event()]);
    let first = true;
    h.setResponder(() => {
      if (first) {
        first = false;
        return new Response("", { status: 503 });
      }
      return new Response(null, { status: 200 });
    });
    assert.equal((await cronAt(h, "2026-10-15T08:29:30Z")).length, 1);
    assert.equal((await cronAt(h, "2026-10-15T08:30:30Z")).length, 1);
    assert.equal((await cronAt(h, "2026-10-15T08:31:30Z")).length, 0);
  });

  it("refuses payloads over 4096 bytes", async () => {
    const h = setup();
    const big = JSON.stringify({ eventID: "ev1", pad: "x".repeat(2100) });
    await register(h, [event({ attributesJSON: big, contentStateJSON: big })]);
    assert.equal((await cronAt(h, "2026-10-15T08:29:30Z")).length, 0);
  });

  it("skips registrations without a token", async () => {
    const h = setup();
    await register(h, [event()], null);
    assert.equal((await cronAt(h, "2026-10-15T08:29:30Z")).length, 0);
  });

  it("sends nothing when APNs is not configured", async () => {
    const h = setup({ APNS_ENV: "" });
    await register(h, [event()]);
    assert.equal((await cronAt(h, "2026-10-15T08:29:30Z")).length, 0);
    const noKey = setup({ APNS_PRIVATE_KEY: "" });
    await register(noKey, [event()]);
    assert.equal((await cronAt(noKey, "2026-10-15T08:29:30Z")).length, 0);
  });

});
