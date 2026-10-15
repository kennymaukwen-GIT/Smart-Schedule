// Request authentication (App Attest assertion, extension session token, or the development token) and
// per-identity rate limiting.
//
// Order of work for an authenticated route, cheapest first, so an unauthenticated caller costs little:
//   1. per-IP failed-authentication budget (KV read)          → 429 rate_limited
//   2. credentials present and well formed                    → 401 attestation_required / invalid_assertion
//   3. key record or session record exists                    → 401 unknown_key / invalid_session
//   4. assertion structure and rpIdHash (no body needed)      → 401 invalid_assertion
//   5. read the body (Content-Length bounded)                 → 413 payload_too_large
//   6. signature over SHA256(body), counter, counter write    → 401 invalid_assertion / stale_counter, 503
// Every 401 adds to the caller IP's failure count for the current minute.

import { AssertionError, checkAssertion, parseAssertion } from "./assertion.ts";
import { b64decode, b64encode, sha256, timingSafeStringEqual } from "./encoding.ts";
import type { Deps, Env } from "./env.ts";
import { rateLimitPerMinute } from "./env.ts";
import { HttpError, log, readBody } from "./http.ts";
import { lookupSession } from "./session.ts";

export interface Identity {
  /** The attested keyId (standard base64), or "dev" for the development token. */
  id: string;
  /** The key's appId (`<teamId>.<bundleId>`); null for "dev". */
  appId: string | null;
}

export interface AuthOptions {
  /** Largest body accepted on this route. */
  maxBody: number;
  /** `Authorization: Session <token>` is accepted only where this is true (/v1beta/*). */
  allowSession: boolean;
}

/** KV `key:<keyId>` — written by POST /attest, counter advanced by every assertion-authenticated request. */
export interface KeyRecord {
  /** Standard base64 of the 65-byte uncompressed P-256 point. */
  publicKey: string;
  counter: number;
  appId: string;
  createdAt: string;
}

export function keyRecordKey(keyId: string): string {
  return `key:${keyId}`;
}

export function clientIp(request: Request): string {
  return request.headers.get("cf-connecting-ip") ?? "unknown";
}

function parseKeyRecord(raw: string | null): { record: KeyRecord; publicKey: Uint8Array } | null {
  if (raw === null) return null;
  try {
    const record = JSON.parse(raw) as KeyRecord;
    const publicKey = typeof record.publicKey === "string" ? b64decode(record.publicKey) : null;
    if (!publicKey || publicKey.length !== 65 || publicKey[0] !== 0x04) return null;
    if (!Number.isInteger(record.counter) || record.counter < 0 || typeof record.appId !== "string") return null;
    return { record, publicKey };
  } catch {
    return null;
  }
}

function retryAfter(now: number): string {
  const minute = Math.floor(now / 60_000);
  return String(Math.max(1, Math.ceil(((minute + 1) * 60_000 - now) / 1000)));
}

function failureKey(ip: string, now: number): string {
  return `rl:authfail:${ip}:${Math.floor(now / 60_000)}`;
}

/** Refuses (before any other work) a caller IP that already failed authentication RATE_LIMIT_PER_MIN times this minute. */
async function checkFailureBudget(env: Env, ip: string, now: number): Promise<void> {
  const count = Number((await env.SS_KV.get(failureKey(ip, now))) ?? "0") || 0;
  if (count >= rateLimitPerMinute(env)) {
    log("warn", "auth_failures_rate_limited", { count });
    throw new HttpError(429, "rate_limited", { "retry-after": retryAfter(now) });
  }
}

async function recordFailure(env: Env, ip: string, now: number): Promise<void> {
  const key = failureKey(ip, now);
  try {
    const count = Number((await env.SS_KV.get(key)) ?? "0") || 0;
    await env.SS_KV.put(key, String(count + 1), { expirationTtl: 120 });
  } catch (e) {
    log("warn", "auth_failure_count_failed", { error: String(e) });
  }
}

/**
 * Authenticates a request and returns its identity with its exact body bytes. Throws HttpError (401/413/429/503).
 *
 * `X-Dev-Token` counts only when ALLOW_DEV_TOKEN is exactly "true" and the token equals SS_DEV_TOKEN (compared in
 * constant time); otherwise it is ignored and `Authorization` decides.
 */
export async function authenticate(request: Request, env: Env, deps: Deps, options: AuthOptions): Promise<{ identity: Identity; body: Uint8Array }> {
  const ip = clientIp(request);
  await checkFailureBudget(env, ip, deps.now());
  try {
    return await authenticateRequest(request, env, deps, options);
  } catch (e) {
    if (e instanceof HttpError && e.status === 401) await recordFailure(env, ip, deps.now());
    throw e;
  }
}

async function authenticateRequest(request: Request, env: Env, deps: Deps, options: AuthOptions): Promise<{ identity: Identity; body: Uint8Array }> {
  const devToken = request.headers.get("x-dev-token");
  if (devToken !== null && env.ALLOW_DEV_TOKEN === "true" && env.SS_DEV_TOKEN) {
    if (await timingSafeStringEqual(devToken, env.SS_DEV_TOKEN)) {
      return { identity: { id: "dev", appId: null }, body: await readBody(request, options.maxBody) };
    }
    log("warn", "dev_token_mismatch");
  }

  const authorization = request.headers.get("authorization");
  const match = authorization ? /^(Bearer|Session)[ ]+(\S+)$/i.exec(authorization.trim()) : null;
  if (!match) throw new HttpError(401, "attestation_required");
  if (match[1]!.toLowerCase() === "session") {
    if (!options.allowSession) {
      log("warn", "session_not_allowed", { path: new URL(request.url).pathname });
      throw new HttpError(401, "attestation_required");
    }
    return sessionAuth(match[2]!, request, env, deps, options);
  }
  return bearerAuth(match[2]!, request, env, deps, options);
}

async function sessionAuth(token: string, request: Request, env: Env, deps: Deps, options: AuthOptions): Promise<{ identity: Identity; body: Uint8Array }> {
  const session = await lookupSession(token, env, deps.now());
  if (!session) throw new HttpError(401, "invalid_session");
  if (session.id === "dev" && env.ALLOW_DEV_TOKEN !== "true") {
    log("warn", "dev_session_rejected");
    throw new HttpError(401, "invalid_session");
  }
  return { identity: { id: session.id, appId: session.appId }, body: await readBody(request, options.maxBody) };
}

async function bearerAuth(raw: string, request: Request, env: Env, deps: Deps, options: AuthOptions): Promise<{ identity: Identity; body: Uint8Array }> {
  const token = b64decode(raw);
  if (!token || token.length <= 32) {
    log("warn", "assertion_rejected", { reason: "malformed bearer token" });
    throw new HttpError(401, "invalid_assertion");
  }
  const keyId = b64encode(token.subarray(0, 32));

  const stored = await env.SS_KV.get(keyRecordKey(keyId));
  if (stored === null) throw new HttpError(401, "unknown_key");
  const key = parseKeyRecord(stored);
  if (!key) {
    log("error", "key_record_corrupt", { keyId });
    throw new HttpError(401, "unknown_key");
  }

  let counter: number;
  let body: Uint8Array;
  try {
    const parsed = await parseAssertion(token.subarray(32), key.record.appId); // before the body is read
    body = await readBody(request, options.maxBody);
    counter = await checkAssertion(parsed, await sha256(body), {
      publicKey: key.publicKey,
      counter: key.record.counter,
      appId: key.record.appId,
    });
  } catch (e) {
    if (e instanceof AssertionError) {
      log("warn", "assertion_rejected", { keyId, code: e.code, reason: e.message });
      throw new HttpError(401, e.code);
    }
    throw e;
  }

  await advanceCounter(env, keyId, counter, deps);
  return { identity: { id: keyId, appId: key.record.appId }, body };
}

/**
 * Stores `counter` for the key before the request is acted on, so the same assertion cannot be used again.
 *
 * The record is re-read immediately before every write (including the retry), and a counter is never written
 * unless it is strictly greater than the stored one: if another request with this counter or a later one got
 * there first, this one is refused with stale_counter (the client retries with a fresh assertion). KV allows one
 * write per second per key, so a failed write is retried once after a pause, then 503 server_busy.
 *
 * Remaining window (KV is not transactional and is eventually consistent): two requests can both pass the
 * re-read before either write lands, or be served by locations that do not yet see each other's write (up to
 * ~60 s), so a replay can still slip through there. A Durable Object per key would make this strict.
 */
async function advanceCounter(env: Env, keyId: string, counter: number, deps: Deps): Promise<void> {
  for (let attempt = 0; attempt < 2; attempt++) {
    if (attempt > 0) await deps.sleep(1100);
    const current = parseKeyRecord(await env.SS_KV.get(keyRecordKey(keyId)));
    if (!current) throw new HttpError(401, "unknown_key");
    if (current.record.counter >= counter) {
      log("warn", "assertion_rejected", { keyId, code: "stale_counter", reason: `counter ${counter} <= stored ${current.record.counter} at write` });
      throw new HttpError(401, "stale_counter");
    }
    try {
      await env.SS_KV.put(keyRecordKey(keyId), JSON.stringify({ ...current.record, counter } satisfies KeyRecord));
      return;
    } catch (e) {
      log("warn", "counter_write_failed", { keyId, attempt, error: String(e) });
    }
  }
  throw new HttpError(503, "server_busy");
}

/**
 * Fixed-window counter per identity and UTC minute in KV (`rl:<id>:<epochMinute>`, TTL 120 s). KV is eventually
 * consistent and allows one write per key per second, so the limit is approximate under bursts (see README).
 * Throws 429 rate_limited with Retry-After when the identity already used its allowance this minute.
 */
export async function enforceRateLimit(env: Env, id: string, now: number): Promise<void> {
  const limit = rateLimitPerMinute(env);
  const key = `rl:${id}:${Math.floor(now / 60_000)}`;
  const count = Number((await env.SS_KV.get(key)) ?? "0") || 0;
  if (count >= limit) {
    log("warn", "rate_limited", { id: id === "dev" ? "dev" : id.startsWith("ip:") ? "ip" : id.slice(0, 12), count });
    throw new HttpError(429, "rate_limited", { "retry-after": retryAfter(now) });
  }
  try {
    await env.SS_KV.put(key, String(count + 1), { expirationTtl: 120 });
  } catch (e) {
    // Best effort: a failed increment (e.g. KV's 1 write/s per key) must not fail an authorized request.
    log("warn", "rate_limit_write_failed", { error: String(e) });
  }
}
