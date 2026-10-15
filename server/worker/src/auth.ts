// Request authentication: App Attest assertion (Bearer), extension session token (Session, /v1beta only), or the
// development token (X-Dev-Token). Rate limiting lives in ratelimit.ts.
//
// Order of work, cheapest first, so an unauthenticated caller costs little and cannot affect anyone else:
//   Bearer   1. token well formed                                    → 401 invalid_assertion
//            2. key:<keyId> exists                                   → 401 unknown_key
//            3. assertion structure and rpIdHash (no body needed)    → 401 invalid_assertion
//            4. body budget for (client IP bucket, keyId)            → 429 rate_limited
//            5. read the body (Content-Length bounded, 2 MB)         → 413 payload_too_large
//            6. signature over SHA256(body), counter, counter write  → 401 invalid_assertion / stale_counter, 503
//               (only these post-body 401s count against the budget in step 4)
//   Session  1. scope: POST /v1beta/models/<SESSION_MODELS>:generateContent, decided before anything else → 403 session_scope
//            2. sess:<hash> exists, not expired (dev: token fingerprint still current) → 401 invalid_session
//            3. read the body (512 KB)
//   Dev      token matches (constant time), then read the body.
// Session and dev credentials are validated before any body is read, so they skip the body budget; cheap rejections
// (no credentials, malformed token, unknown key, unknown session) are not counted anywhere.

import { AssertionError, checkAssertion, parseAssertion } from "./assertion.ts";
import { b64decode, b64encode, sha256, timingSafeStringEqual } from "./encoding.ts";
import type { Deps, Env } from "./env.ts";
import { HttpError, log, readBody } from "./http.ts";
import { checkBodyBudget, clientIp, recordBodyFailure } from "./ratelimit.ts";
import { devKeyOf, lookupSession } from "./session.ts";

export interface Identity {
  /** The attested keyId (standard base64), or "dev" for the development token. */
  id: string;
  /** The key's appId (`<teamId>.<bundleId>`); null for "dev". */
  appId: string | null;
}

/** How the request authenticated: Session and dev identities get the strict (write-mandatory) rate limit. */
export type Credential = "assertion" | "session" | "dev";

export interface AuthResult {
  identity: Identity;
  body: Uint8Array;
  via: Credential;
}

export interface AuthOptions {
  /** Largest body accepted with an assertion or the dev token. */
  maxBody: number;
  /** Only where Session tokens are accepted (/v1beta/*): their body cap and the models they may call. */
  session?: { maxBody: number; models: string[] };
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

/**
 * Authenticates a request and returns its identity with its exact body bytes. Throws HttpError (401/403/413/429/503).
 *
 * `X-Dev-Token` counts only when ALLOW_DEV_TOKEN is exactly "true" and the token equals SS_DEV_TOKEN (compared in
 * constant time); otherwise it is ignored and `Authorization` decides.
 */
export async function authenticate(request: Request, env: Env, deps: Deps, options: AuthOptions): Promise<AuthResult> {
  const devToken = request.headers.get("x-dev-token");
  if (devToken !== null && env.ALLOW_DEV_TOKEN === "true" && env.SS_DEV_TOKEN) {
    if (await timingSafeStringEqual(devToken, env.SS_DEV_TOKEN)) {
      return { identity: { id: "dev", appId: null }, body: await readBody(request, options.maxBody), via: "dev" };
    }
    log("warn", "dev_token_mismatch");
  }

  const authorization = request.headers.get("authorization");
  const match = authorization ? /^(Bearer|Session)[ ]+(\S+)$/i.exec(authorization.trim()) : null;
  if (!match) throw new HttpError(401, "attestation_required");
  if (match[1]!.toLowerCase() === "session") {
    if (!options.session) {
      log("warn", "session_not_allowed", { path: new URL(request.url).pathname });
      throw new HttpError(401, "attestation_required");
    }
    return sessionAuth(match[2]!, request, env, deps, options.session);
  }
  return bearerAuth(match[2]!, request, env, deps, options);
}

/** The one call the notification extension makes: POST /v1beta/models/<allowed model>:generateContent. */
export function sessionScopeAllows(request: Request, models: string[]): boolean {
  if (request.method.toUpperCase() !== "POST") return false;
  const m = /^\/v1beta\/models\/([A-Za-z0-9._-]+):generateContent$/.exec(new URL(request.url).pathname);
  return m !== null && models.includes(m[1]!);
}

async function sessionAuth(token: string, request: Request, env: Env, deps: Deps, scope: NonNullable<AuthOptions["session"]>): Promise<AuthResult> {
  // Scope first: a Session token is readable by the device's owner, so it never reaches anything else.
  if (!sessionScopeAllows(request, scope.models)) {
    const pathname = new URL(request.url).pathname;
    // The model shows old app builds still sending a model that SESSION_MODELS no longer lists.
    const model = /^\/v1beta\/models\/([^/:]+)/.exec(pathname)?.[1]?.slice(0, 100) ?? null;
    log("warn", "session_scope_refused", { method: request.method, model, path: pathname.slice(0, 120) });
    throw new HttpError(403, "session_scope");
  }
  const session = await lookupSession(token, env, deps.now());
  if (!session) throw new HttpError(401, "invalid_session");
  if (session.id === "dev") {
    const current = env.ALLOW_DEV_TOKEN === "true" && env.SS_DEV_TOKEN ? await devKeyOf(env.SS_DEV_TOKEN) : null;
    if (!current || !session.devKey || !(await timingSafeStringEqual(session.devKey, current))) {
      log("warn", "dev_session_rejected", { reason: current ? "minted with another dev token" : "dev token disabled or removed" });
      throw new HttpError(401, "invalid_session");
    }
  }
  return { identity: { id: session.id, appId: session.appId }, body: await readBody(request, scope.maxBody), via: "session" };
}

async function bearerAuth(raw: string, request: Request, env: Env, deps: Deps, options: AuthOptions): Promise<AuthResult> {
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

  let parsed;
  try {
    parsed = await parseAssertion(token.subarray(32), key.record.appId);
  } catch (e) {
    if (e instanceof AssertionError) {
      log("warn", "assertion_rejected", { keyId, code: e.code, reason: e.message });
      throw new HttpError(401, e.code);
    }
    throw e;
  }

  // Only now is reading an unauthenticated body worth guarding: budget per (client IP bucket, keyId).
  const bucket = clientIp(request);
  await checkBodyBudget(env, bucket, keyId, deps.now());
  try {
    const body = await readBody(request, options.maxBody);
    let counter: number;
    try {
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
    return { identity: { id: keyId, appId: key.record.appId }, body, via: "assertion" };
  } catch (e) {
    if (e instanceof HttpError && e.status === 401) await recordBodyFailure(env, bucket, keyId, deps.now());
    throw e;
  }
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
