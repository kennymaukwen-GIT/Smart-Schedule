// POST /devices/push-to-start — whole-replace registration of the events a device wants Live Activities for.
//
// KV layout (see README); <eventHash> = hex SHA-256 of the eventID (EventKit / Google IDs can be long and contain ':'):
//   p2s:<deviceID>                                     registration { token, keyId, appId, events, updatedAt } (TTL 3 days)
//   due:<YYYYMMDDHHmm>:<deviceID>:<eventHash>          index for the cron, minute of triggerAt UTC (TTL until triggerAt + 1 h)
//   sent:<deviceID>:<eventHash>:<triggerAt epoch s>    sent marker, written by the cron (TTL 3 days), never by this route
//   claim:<deviceID>:<eventHash>:<triggerAt epoch s>   in-flight marker while the cron sends (TTL 120 s)
//   p2sdead:<deviceID>                                 a push token APNs rejected (cron only; TTL 3 days)

import type { Identity } from "./auth.ts";
import { keyRecordKey } from "./auth.ts";
import { hex, sha256, utf8, utf8Length } from "./encoding.ts";
import type { Deps, Env } from "./env.ts";
import { HttpError, json, log, parseJson } from "./http.ts";

export const REGISTRATION_TTL_SECONDS = 3 * 24 * 3600;
export const SENT_TTL_SECONDS = 3 * 24 * 3600;
const MAX_EVENTS = 50;
const MAX_TITLE_CODE_POINTS = 200;
const MAX_EMBEDDED_JSON_BYTES = 4096;
const MAX_EVENT_ID_BYTES = 1024;
const MAX_LEAD_MINUTES = 1440;
const TRIGGER_PAST_MS = 3600_000;
const TRIGGER_FUTURE_MS = 49 * 3600_000;

export interface StoredEvent {
  eventID: string;
  title: string;
  eventStart: string;
  leadTime: number;
  triggerAt: string;
  attributesJSON: string;
  contentStateJSON: string;
}

export interface Registration {
  token: string | null;
  /** The identity that last wrote this registration: an attested keyId or "dev" (for logs and the dev/app check). */
  keyId: string;
  /** That identity's appId; null for "dev". */
  appId?: string | null;
  events: StoredEvent[];
  updatedAt: string;
}

export function registrationKey(deviceID: string): string {
  return `p2s:${deviceID}`;
}

export function deadTokenKey(deviceID: string): string {
  return `p2sdead:${deviceID}`;
}

/** Hex SHA-256 of an eventID: what the due:, sent: and claim: keys carry instead of the ID itself. */
export async function eventHash(eventID: string): Promise<string> {
  return hex(await sha256(utf8(eventID)));
}

/** UTC YYYYMMDDHHmm of an epoch-millisecond instant. */
export function minuteStamp(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}`;
}

export function dueKey(triggerAtMs: number, deviceID: string, hash: string): string {
  return `due:${minuteStamp(triggerAtMs)}:${deviceID}:${hash}`;
}

export function sentKey(deviceID: string, hash: string, triggerAtMs: number): string {
  return `sent:${deviceID}:${hash}:${Math.floor(triggerAtMs / 1000)}`;
}

export function claimKey(deviceID: string, hash: string, triggerAtMs: number): string {
  return `claim:${deviceID}:${hash}:${Math.floor(triggerAtMs / 1000)}`;
}

/** Parses `due:<YYYYMMDDHHmm>:<deviceID>:<eventHash>`. */
export function parseDueKey(name: string): { minute: string; deviceID: string; hash: string } | null {
  const m = /^due:(\d{12}):([A-Za-z0-9-]{1,64}):([0-9a-f]{64})$/.exec(name);
  return m ? { minute: m[1]!, deviceID: m[2]!, hash: m[3]! } : null;
}

const ISO_8601 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/;

/** Epoch ms of an ISO 8601 date-time as Swift's `.iso8601` strategy writes it, or null. */
export function parseIsoDate(value: unknown): number | null {
  if (typeof value !== "string" || !ISO_8601.test(value)) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

function isJsonObjectText(value: unknown): value is string {
  if (typeof value !== "string" || utf8Length(value) > MAX_EMBEDDED_JSON_BYTES) return false;
  try {
    const parsed: unknown = JSON.parse(value);
    return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed);
  } catch {
    return false;
  }
}

class InvalidRegistration extends Error {}

function invalid(reason: string): never {
  throw new InvalidRegistration(reason);
}

export interface ValidRegistration {
  deviceID: string;
  token: string | null;
  events: StoredEvent[];
  /** Events left out, with the reason (never their content). */
  skipped: { index: number; reason: string }[];
}

/** One event, or the reason it is left out. A long title is shortened, not refused. */
function validateEvent(raw: unknown, now: number): StoredEvent | string {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return "not an object";
  const e = raw as Record<string, unknown>;
  const { eventID, title, leadTime, attributesJSON, contentStateJSON } = e;
  if (typeof eventID !== "string" || eventID.length === 0 || utf8Length(eventID) > MAX_EVENT_ID_BYTES || /[\u0000-\u001f\u007f]/.test(eventID)) {
    return "eventID";
  }
  if (typeof title !== "string") return "title";
  if (parseIsoDate(e.eventStart) === null) return "eventStart";
  if (typeof leadTime !== "number" || !Number.isInteger(leadTime) || leadTime < 0 || leadTime > MAX_LEAD_MINUTES) return "leadTime";
  const triggerAt = parseIsoDate(e.triggerAt);
  if (triggerAt === null) return "triggerAt";
  if (triggerAt < now - TRIGGER_PAST_MS || triggerAt > now + TRIGGER_FUTURE_MS) return "triggerAt out of range";
  if (!isJsonObjectText(attributesJSON)) return "attributesJSON";
  if (!isJsonObjectText(contentStateJSON)) return "contentStateJSON";
  const codePoints = Array.from(title);
  return {
    eventID,
    title: codePoints.length > MAX_TITLE_CODE_POINTS ? codePoints.slice(0, MAX_TITLE_CODE_POINTS).join("") : title,
    eventStart: e.eventStart as string,
    leadTime,
    triggerAt: e.triggerAt as string,
    attributesJSON,
    contentStateJSON,
  };
}

/**
 * Body-level problems throw InvalidRegistration (→ 400); a bad event is only left out, so one odd calendar entry
 * never blocks the whole upload. Unknown fields are dropped, never stored.
 */
export function validateRegistration(body: unknown, now: number): ValidRegistration {
  if (typeof body !== "object" || body === null || Array.isArray(body)) invalid("body is not an object");
  const b = body as Record<string, unknown>;

  const deviceID = b.deviceID;
  if (typeof deviceID !== "string" || !/^[A-Za-z0-9-]{1,64}$/.test(deviceID)) invalid("deviceID");

  // Swift's synthesized Encodable omits a nil Optional, so a missing token means null.
  let token: string | null = null;
  if (b.token !== undefined && b.token !== null) {
    if (typeof b.token !== "string" || !/^[0-9A-Fa-f]{1,200}$/.test(b.token)) invalid("token");
    token = b.token;
  }

  if (!Array.isArray(b.events)) invalid("events is not an array");
  if (b.events.length > MAX_EVENTS) invalid("too many events");

  const events: StoredEvent[] = [];
  const skipped: { index: number; reason: string }[] = [];
  b.events.forEach((raw: unknown, index: number) => {
    const result = validateEvent(raw, now);
    if (typeof result === "string") skipped.push({ index, reason: result });
    else events.push(result);
  });
  return { deviceID, token, events, skipped };
}

export function parseRegistration(raw: string | null): Registration | null {
  if (raw === null) return null;
  try {
    const r = JSON.parse(raw) as Registration;
    return typeof r === "object" && r !== null && typeof r.keyId === "string" && Array.isArray(r.events) ? r : null;
  } catch {
    return null;
  }
}

/** appId of the identity that wrote `existing` (older records only name the key: look it up). */
async function previousAppId(existing: Registration, env: Env): Promise<string | null> {
  if (typeof existing.appId === "string") return existing.appId;
  try {
    const record = JSON.parse((await env.SS_KV.get(keyRecordKey(existing.keyId))) ?? "null") as { appId?: unknown } | null;
    return typeof record?.appId === "string" ? record.appId : null;
  } catch {
    return null;
  }
}

/**
 * The random 122-bit deviceID is the capability: any attested identity of the same app may take a registration
 * over (an App Attest key rotation or a restore to a new phone must not lock the device out). Refused only when
 * the development identity and an attested one would overwrite each other, or the apps differ.
 */
async function checkWriter(existing: Registration | null, identity: Identity, deviceID: string, env: Env): Promise<void> {
  if (!existing) return;
  const existingDev = existing.keyId === "dev";
  const writerDev = identity.id === "dev";
  if (existingDev !== writerDev) {
    log("warn", "registration_forbidden", { deviceID, reason: "dev and attested identities cannot share a deviceID" });
    throw new HttpError(403, "forbidden");
  }
  if (writerDev || existing.keyId === identity.id) return;
  const appId = await previousAppId(existing, env);
  if (appId !== null && appId !== identity.appId) {
    log("warn", "registration_forbidden", { deviceID, reason: "registered by another app" });
    throw new HttpError(403, "forbidden");
  }
  log("info", "registration_rebound", { deviceID, from: existing.keyId.slice(0, 12), to: identity.id.slice(0, 12), appId: identity.appId });
}

export async function handlePushToStart(body: Uint8Array, identity: Identity, env: Env, deps: Deps): Promise<Response> {
  const now = deps.now();
  let valid: ValidRegistration;
  try {
    valid = validateRegistration(parseJson(body), now);
  } catch (e) {
    if (e instanceof InvalidRegistration) {
      log("warn", "registration_rejected", { reason: e.message });
      throw new HttpError(400, "invalid_registration");
    }
    throw e;
  }
  if (valid.skipped.length) log("warn", "registration_events_skipped", { deviceID: valid.deviceID, skipped: valid.skipped });

  const kvKey = registrationKey(valid.deviceID);
  const existing = parseRegistration(await env.SS_KV.get(kvKey));
  await checkWriter(existing, identity, valid.deviceID, env);

  // Index keys first, so a stored registration never names an event the cron cannot find. An index key that the
  // previous registration already wrote for the same (eventID, triggerAt) still exists (it lives until
  // triggerAt + 1 h), so it is not written again; stale ones for moved or deleted events are harmless.
  const alreadyIndexed = new Set((existing?.events ?? []).map((e) => `${e.eventID}\u0000${Date.parse(e.triggerAt)}`));
  const pending = new Map<string, number>(); // due key → TTL; a Map so duplicate events write once
  for (const event of valid.events) {
    const triggerAt = Date.parse(event.triggerAt);
    if (alreadyIndexed.has(`${event.eventID}\u0000${triggerAt}`)) continue;
    pending.set(dueKey(triggerAt, valid.deviceID, await eventHash(event.eventID)), Math.max(60, Math.ceil((triggerAt + 3600_000 - now) / 1000)));
  }

  const registration: Registration = {
    token: valid.token,
    keyId: identity.id,
    appId: identity.appId,
    events: valid.events,
    updatedAt: new Date(now).toISOString(),
  };
  try {
    await Promise.all([...pending].map(([key, ttl]) => env.SS_KV.put(key, "1", { expirationTtl: ttl })));
    await env.SS_KV.put(kvKey, JSON.stringify(registration), { expirationTtl: REGISTRATION_TTL_SECONDS });
  } catch (e) {
    // e.g. KV's one-write-per-second-per-key limit when the same device uploads twice in a row; the client retries.
    log("error", "registration_write_failed", { deviceID: valid.deviceID, error: String(e) });
    throw new HttpError(503, "server_busy");
  }
  log("info", "registration_stored", { deviceID: valid.deviceID, events: valid.events.length, skipped: valid.skipped.length, hasToken: valid.token !== null });
  return json(200, { ok: true, events: valid.events.length });
}
