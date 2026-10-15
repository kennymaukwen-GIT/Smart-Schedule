// Rate limiting: per identity, per client IP (unauthenticated /attest*), and the per-(IP, key) budget that guards the
// one expensive unauthenticated step (reading a Bearer request's body).
//
// Two backends:
//   • SS_RATE_LIMITER — Cloudflare's Rate Limiting binding (`[[ratelimits]]`): counts atomically within a location
//     and needs no KV writes. Keys: `id:<identity>`, `ip:<bucket>`, `pre:<bucket>:<keyId>`.
//   • KV fixed-window counters (`rl:…:<epochMinute>`, TTL 120 s): global but read-modify-write, so approximate; used
//     for identities always (a second, global layer) and for the IP limits only when the binding is absent.

import type { Env } from "./env.ts";
import { attestDailyPerIp, rateLimitPerMinute, sessionDailyLimit } from "./env.ts";
import { HttpError, log } from "./http.ts";

function minuteOf(now: number): number {
  return Math.floor(now / 60_000);
}

function untilNextMinute(now: number): string {
  return String(Math.max(1, Math.ceil(((minuteOf(now) + 1) * 60_000 - now) / 1000)));
}

function limited(retryAfter: string, event: string, fields: Record<string, unknown> = {}): never {
  log("warn", event, fields);
  throw new HttpError(429, "rate_limited", { "retry-after": retryAfter });
}

function expandIpv6(address: string): string[] | null {
  let s = address.split("%")[0]!; // drop a zone index
  const v4 = /(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
  if (v4) {
    const [a, b, c, d] = v4.slice(1).map(Number) as [number, number, number, number];
    if ([a, b, c, d].some((n) => n > 255)) return null;
    s = `${s.slice(0, v4.index)}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }
  const halves = s.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const fill = halves.length === 2 ? 8 - head.length - tail.length : 0;
  if (fill < 0 || (halves.length === 2 && fill < 1)) return null;
  const all = [...head, ...Array<string>(fill).fill("0"), ...tail];
  return all.length === 8 && all.every((h) => /^[0-9a-fA-F]{1,4}$/.test(h)) ? all : null;
}

/**
 * The rate-limit bucket for a client address: IPv4 as is; IPv6 by its /64 (a host controls at least a /64, so a
 * per-address key would never trip), e.g. `v6:2001:db8:1:2::/64`; IPv4-mapped IPv6 as the IPv4 address.
 */
export function ipBucket(raw: string | null): string {
  const ip = raw?.trim();
  if (!ip) return "unknown";
  if (!ip.includes(":")) return ip.slice(0, 45);
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i.exec(ip);
  if (mapped) return mapped[1]!;
  const hextets = expandIpv6(ip);
  if (!hextets) return `v6:${ip.slice(0, 45)}`;
  return `v6:${hextets.slice(0, 4).map((h) => parseInt(h, 16).toString(16)).join(":")}::/64`;
}

export function clientIp(request: Request): string {
  return ipBucket(request.headers.get("cf-connecting-ip"));
}

/**
 * Per-identity limit (keyId, "dev"; a session counts as its keyId). The binding, when bound, counts atomically but only
 * per location; the KV counter is the global layer, so its write stays mandatory for `strict` identities (Session and
 * dev, which have no other per-request write) even with the binding bound. A failed strict write is answered with
 * 503 server_busy + Retry-After: 1 — usually a harmless collision with another write to the same key in the same
 * second (KV allows one), which the app retries after 0.8 s and 1.6 s — never let through uncounted, so a burst is
 * still refused. Bearer requests are already throttled by their own counter write, so theirs is best effort.
 */
export async function enforceRateLimit(env: Env, id: string, now: number, options: { strict: boolean }): Promise<void> {
  const label = id === "dev" ? "dev" : id.slice(0, 12);
  if (env.SS_RATE_LIMITER && !(await env.SS_RATE_LIMITER.limit({ key: `id:${id}` })).success) {
    limited(untilNextMinute(now), "rate_limited", { id: label, by: "binding" });
  }
  const key = `rl:${id}:${minuteOf(now)}`;
  const count = Number((await env.SS_KV.get(key)) ?? "0") || 0;
  if (count >= rateLimitPerMinute(env)) limited(untilNextMinute(now), "rate_limited", { id: label, count });
  try {
    await env.SS_KV.put(key, String(count + 1), { expirationTtl: 120 });
  } catch (e) {
    log("warn", "rate_limit_write_failed", { id: label, strict: options.strict, error: String(e) });
    if (options.strict) throw new HttpError(503, "server_busy", { "retry-after": "1" });
  }
}

/** Per-IP-bucket limit for the unauthenticated /attest* routes; with the binding bound it causes no KV write. */
export async function enforceIpLimit(env: Env, bucket: string, now: number): Promise<void> {
  if (env.SS_RATE_LIMITER) {
    if (!(await env.SS_RATE_LIMITER.limit({ key: `ip:${bucket}` })).success) limited(untilNextMinute(now), "ip_rate_limited", { by: "binding" });
    return;
  }
  const key = `rl:ip:${bucket}:${minuteOf(now)}`;
  const count = Number((await env.SS_KV.get(key)) ?? "0") || 0;
  if (count >= rateLimitPerMinute(env)) limited(untilNextMinute(now), "ip_rate_limited", { count });
  try {
    await env.SS_KV.put(key, String(count + 1), { expirationTtl: 120 });
  } catch (e) {
    log("warn", "rate_limit_write_failed", { error: String(e) });
  }
}

function failureKey(bucket: string, keyId: string, now: number): string {
  return `rl:authfail:${bucket}:${keyId}:${minuteOf(now)}`;
}

/**
 * Called right before a Bearer request's body is read — only once its key exists and its assertion parsed with the
 * right rpIdHash — and keyed by (IP bucket, keyId), so garbage from a shared IP cannot lock anyone else out.
 * With the binding: every attempt that reaches this point counts (the binding cannot check without counting), with no
 * KV write. Without it: refuses once RATE_LIMIT_PER_MIN failures were recorded this minute (recordBodyFailure).
 */
export async function checkBodyBudget(env: Env, bucket: string, keyId: string, now: number): Promise<void> {
  if (env.SS_RATE_LIMITER) {
    if (!(await env.SS_RATE_LIMITER.limit({ key: `pre:${bucket}:${keyId}` })).success) {
      limited(untilNextMinute(now), "auth_budget_exhausted", { keyId: keyId.slice(0, 12), by: "binding" });
    }
    return;
  }
  const count = Number((await env.SS_KV.get(failureKey(bucket, keyId, now))) ?? "0") || 0;
  if (count >= rateLimitPerMinute(env)) limited(untilNextMinute(now), "auth_budget_exhausted", { keyId: keyId.slice(0, 12), count });
}

/** A 401 after the body was read (bad signature, stale counter). Only the KV backend needs to record it. */
export async function recordBodyFailure(env: Env, bucket: string, keyId: string, now: number): Promise<void> {
  if (env.SS_RATE_LIMITER) return;
  const key = failureKey(bucket, keyId, now);
  try {
    const count = Number((await env.SS_KV.get(key)) ?? "0") || 0;
    await env.SS_KV.put(key, String(count + 1), { expirationTtl: 120 });
  } catch (e) {
    log("warn", "auth_failure_count_failed", { error: String(e) });
  }
}

// Daily caps (KV; the binding's period is at most 60 s). A device owner can mint attested identities (reinstall,
// "Erase all data", a proxy that forces re-attestation), so per-identity limits do not bound a device; these raise the
// cost: each identity's session gets a daily allowance, and each IP bucket a daily number of new identities.

const DAY_MS = 86_400_000;
const DAILY_COUNTER_TTL_SECONDS = 2 * 86_400;

function utcDay(now: number): string {
  return new Date(now).toISOString().slice(0, 10).replace(/-/g, "");
}

function untilNextUtcDay(now: number): string {
  return String(Math.max(1, Math.ceil(((Math.floor(now / DAY_MS) + 1) * DAY_MS - now) / 1000)));
}

/** Best-effort read-modify-write; fine at a daily granularity (the per-minute limits catch bursts). */
async function bumpDaily(env: Env, key: string, count: number): Promise<void> {
  try {
    await env.SS_KV.put(key, String(count + 1), { expirationTtl: DAILY_COUNTER_TTL_SECONDS });
  } catch (e) {
    log("warn", "daily_counter_write_failed", { error: String(e) });
  }
}

/** Session-authenticated generateContent per identity and UTC day (`rl:sday:<id>:<YYYYMMDD>`). Bearer is not counted. */
export async function enforceSessionDailyLimit(env: Env, id: string, now: number): Promise<void> {
  const key = `rl:sday:${id}:${utcDay(now)}`;
  const count = Number((await env.SS_KV.get(key)) ?? "0") || 0;
  if (count >= sessionDailyLimit(env)) {
    limited(untilNextUtcDay(now), "session_daily_limit", { id: id === "dev" ? "dev" : id.slice(0, 12), count });
  }
  await bumpDaily(env, key, count);
}

function attestDayKey(bucket: string, now: number): string {
  return `rl:attestday:${bucket}:${utcDay(now)}`;
}

/** Refuses /attest/challenge and /attest for an IP bucket that already attested ATTEST_DAILY_PER_IP keys today. */
export async function checkAttestDaily(env: Env, bucket: string, now: number): Promise<void> {
  const count = Number((await env.SS_KV.get(attestDayKey(bucket, now))) ?? "0") || 0;
  if (count >= attestDailyPerIp(env)) limited(untilNextUtcDay(now), "attest_daily_limit", { count });
}

/** Counts a successful attestation for its IP bucket (only successes: failed attempts are not new identities). */
export async function recordAttestSuccess(env: Env, bucket: string, now: number): Promise<void> {
  const key = attestDayKey(bucket, now);
  const count = Number((await env.SS_KV.get(key)) ?? "0") || 0;
  await bumpDaily(env, key, count);
}
