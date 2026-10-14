// Request authentication (App Attest assertion or the development token) and per-identity rate limiting.

import { AssertionError, verifyAssertion } from "./assertion.ts";
import { b64decode, b64encode, sha256, timingSafeStringEqual } from "./encoding.ts";
import type { Deps, Env, KV } from "./env.ts";
import { rateLimitPerMinute } from "./env.ts";
import { HttpError, log, readBody } from "./http.ts";

export interface Identity {
  /** The attested keyId (standard base64), or "dev" for the development token. */
  id: string;
}

/** KV `key:<keyId>` — written by POST /attest, counter advanced by every authenticated request. */
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

function parseKeyRecord(raw: string): { record: KeyRecord; publicKey: Uint8Array } | null {
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

/**
 * Authenticates a request and returns its identity together with its exact body bytes (read here, up to
 * `maxBody`, only after the credentials passed the cheap checks). Throws HttpError(401/413/503) on failure.
 *
 * `X-Dev-Token` counts only when ALLOW_DEV_TOKEN is exactly "true" and the token equals SS_DEV_TOKEN (compared in
 * constant time); otherwise it is ignored and the Bearer assertion is required.
 */
export async function authenticate(request: Request, env: Env, deps: Deps, maxBody: number): Promise<{ identity: Identity; body: Uint8Array }> {
  const devToken = request.headers.get("x-dev-token");
  if (devToken !== null && env.ALLOW_DEV_TOKEN === "true" && env.SS_DEV_TOKEN) {
    if (await timingSafeStringEqual(devToken, env.SS_DEV_TOKEN)) return { identity: { id: "dev" }, body: await readBody(request, maxBody) };
    log("warn", "dev_token_mismatch");
  }

  const authorization = request.headers.get("authorization");
  const match = authorization ? /^Bearer[ ]+(\S+)$/i.exec(authorization.trim()) : null;
  if (!match) throw new HttpError(401, "attestation_required");

  const token = b64decode(match[1]!);
  if (!token || token.length <= 32) {
    log("warn", "assertion_rejected", { reason: "malformed bearer token" });
    throw new HttpError(401, "invalid_assertion");
  }
  const keyId = b64encode(token.subarray(0, 32));
  const assertion = token.subarray(32);

  const stored = await env.SS_KV.get(keyRecordKey(keyId));
  if (stored === null) throw new HttpError(401, "unknown_key");
  const parsed = parseKeyRecord(stored);
  if (!parsed) {
    log("error", "key_record_corrupt", { keyId });
    throw new HttpError(401, "unknown_key");
  }

  const body = await readBody(request, maxBody);
  const clientDataHash = await sha256(body);
  let counter: number;
  try {
    counter = await verifyAssertion(assertion, clientDataHash, {
      publicKey: parsed.publicKey,
      counter: parsed.record.counter,
      appId: parsed.record.appId,
    });
  } catch (e) {
    if (e instanceof AssertionError) {
      log("warn", "assertion_rejected", { keyId, code: e.code, reason: e.message });
      throw new HttpError(401, e.code);
    }
    throw e;
  }

  // Persist the counter before acting on the request, so the same assertion cannot be replayed later.
  const updated: KeyRecord = { ...parsed.record, counter };
  await putWithRetry(env.SS_KV, keyRecordKey(keyId), JSON.stringify(updated), undefined, deps);
  return { identity: { id: keyId }, body };
}

/**
 * KV rejects more than one write per second to the same key; retry once after a pause, then give up with 503
 * rather than act on a request whose counter could not be recorded.
 */
async function putWithRetry(kv: KV, key: string, value: string, options: { expirationTtl?: number } | undefined, deps: Deps): Promise<void> {
  try {
    await kv.put(key, value, options);
    return;
  } catch (e) {
    log("warn", "kv_put_retry", { key: key.slice(0, 16), error: String(e) });
  }
  await deps.sleep(1100);
  try {
    await kv.put(key, value, options);
  } catch (e) {
    log("error", "kv_put_failed", { key: key.slice(0, 16), error: String(e) });
    throw new HttpError(503, "server_busy");
  }
}

/**
 * Fixed-window counter per identity and UTC minute in KV (`rl:<id>:<epochMinute>`, TTL 120 s). KV is eventually
 * consistent and allows one write per key per second, so the limit is approximate under bursts (see README).
 * Throws 429 rate_limited with Retry-After when the identity already used its allowance this minute.
 */
export async function enforceRateLimit(env: Env, id: string, now: number): Promise<void> {
  const limit = rateLimitPerMinute(env);
  const minute = Math.floor(now / 60_000);
  const key = `rl:${id}:${minute}`;
  const count = Number((await env.SS_KV.get(key)) ?? "0") || 0;
  if (count >= limit) {
    const retryAfter = Math.max(1, Math.ceil(((minute + 1) * 60_000 - now) / 1000));
    log("warn", "rate_limited", { id: id === "dev" ? "dev" : id.slice(0, 12), count });
    throw new HttpError(429, "rate_limited", { "retry-after": String(retryAfter) });
  }
  try {
    await env.SS_KV.put(key, String(count + 1), { expirationTtl: 120 });
  } catch (e) {
    // Best effort: a failed increment (e.g. KV's 1 write/s per key) must not fail an authorized request.
    log("warn", "rate_limit_write_failed", { error: String(e) });
  }
}
