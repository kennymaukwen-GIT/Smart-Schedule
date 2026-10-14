// POST /devices/push-to-start — whole-replace registration of the events a device wants Live Activities for.
//
// KV layout (see README):
//   p2s:<deviceID>                                   registration { token, keyId, events, updatedAt, tokenInvalidAt? } (TTL 3 days)
//   due:<YYYYMMDDHHmm>:<deviceID>:<eventID>          index for the cron, minute of triggerAt UTC (TTL until triggerAt + 1 h)
//   sent:<deviceID>:<eventID>:<triggerAt epoch s>    sent marker, written by the cron (TTL 3 days), never by this route

import type { Identity } from "./auth.ts";
import { utf8Length } from "./encoding.ts";
import type { Deps, Env } from "./env.ts";
import { HttpError, json, log, parseJson } from "./http.ts";

export const REGISTRATION_TTL_SECONDS = 3 * 24 * 3600;
export const SENT_TTL_SECONDS = 3 * 24 * 3600;
const MAX_EVENTS = 50;
const MAX_TITLE_CHARS = 200;
const MAX_EMBEDDED_JSON_BYTES = 4096;
const MAX_EVENT_ID_BYTES = 256;
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
  /** The identity that first registered this deviceID: an attested keyId or "dev". */
  keyId: string;
  events: StoredEvent[];
  updatedAt: string;
  tokenInvalidAt?: string;
}

export function registrationKey(deviceID: string): string {
  return `p2s:${deviceID}`;
}

/** UTC YYYYMMDDHHmm of an epoch-millisecond instant. */
export function minuteStamp(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}`;
}

export function dueKey(triggerAtMs: number, deviceID: string, eventID: string): string {
  return `due:${minuteStamp(triggerAtMs)}:${deviceID}:${eventID}`;
}

export function sentKey(deviceID: string, eventID: string, triggerAtMs: number): string {
  return `sent:${deviceID}:${eventID}:${Math.floor(triggerAtMs / 1000)}`;
}

/** Parses `due:<YYYYMMDDHHmm>:<deviceID>:<eventID>`; the eventID may itself contain ':' (EventKit identifiers do). */
export function parseDueKey(name: string): { minute: string; deviceID: string; eventID: string } | null {
  const m = /^due:(\d{12}):([A-Za-z0-9-]{1,64}):(.+)$/s.exec(name);
  return m ? { minute: m[1]!, deviceID: m[2]!, eventID: m[3]! } : null;
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
}

/** Validates the body; throws InvalidRegistration with the reason. Unknown fields are dropped, never stored. */
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

  const events = b.events.map((raw: unknown, i: number): StoredEvent => {
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) invalid(`events[${i}] is not an object`);
    const e = raw as Record<string, unknown>;
    const { eventID, title, leadTime, attributesJSON, contentStateJSON } = e;
    if (
      typeof eventID !== "string" ||
      eventID.length === 0 ||
      utf8Length(eventID) > MAX_EVENT_ID_BYTES ||
      /[\u0000-\u001f\u007f]/.test(eventID)
    ) {
      invalid(`events[${i}].eventID`);
    }
    if (typeof title !== "string" || Array.from(title).length > MAX_TITLE_CHARS) invalid(`events[${i}].title`);
    if (parseIsoDate(e.eventStart) === null) invalid(`events[${i}].eventStart`);
    if (typeof leadTime !== "number" || !Number.isInteger(leadTime) || leadTime < 0 || leadTime > MAX_LEAD_MINUTES) {
      invalid(`events[${i}].leadTime`);
    }
    const triggerAt = parseIsoDate(e.triggerAt);
    if (triggerAt === null) invalid(`events[${i}].triggerAt`);
    if (triggerAt < now - TRIGGER_PAST_MS || triggerAt > now + TRIGGER_FUTURE_MS) invalid(`events[${i}].triggerAt out of range`);
    if (!isJsonObjectText(attributesJSON)) invalid(`events[${i}].attributesJSON`);
    if (!isJsonObjectText(contentStateJSON)) invalid(`events[${i}].contentStateJSON`);
    return {
      eventID,
      title,
      eventStart: e.eventStart as string,
      leadTime,
      triggerAt: e.triggerAt as string,
      attributesJSON,
      contentStateJSON,
    };
  });
  return { deviceID, token, events };
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

  const kvKey = registrationKey(valid.deviceID);
  const existing = parseRegistration(await env.SS_KV.get(kvKey));
  if (existing && existing.keyId !== identity.id) {
    log("warn", "registration_forbidden", { deviceID: valid.deviceID });
    throw new HttpError(403, "forbidden");
  }

  // Index keys first, so a stored registration never names an event the cron cannot find. An index key that the
  // previous registration already wrote for the same (eventID, triggerAt) still exists (it lives until
  // triggerAt + 1 h), so it is not written again; stale ones for moved or deleted events are harmless.
  const alreadyIndexed = new Set((existing?.events ?? []).map((e) => `${e.eventID}\u0000${Date.parse(e.triggerAt)}`));
  const pending = new Map<string, number>(); // due key → TTL; a Map so duplicate events write once
  for (const event of valid.events) {
    const triggerAt = Date.parse(event.triggerAt);
    if (alreadyIndexed.has(`${event.eventID}\u0000${triggerAt}`)) continue;
    pending.set(dueKey(triggerAt, valid.deviceID, event.eventID), Math.max(60, Math.ceil((triggerAt + 3600_000 - now) / 1000)));
  }

  const registration: Registration = {
    token: valid.token,
    keyId: identity.id,
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
  log("info", "registration_stored", { deviceID: valid.deviceID, events: valid.events.length, hasToken: valid.token !== null });
  return json(200, { ok: true, events: valid.events.length });
}
