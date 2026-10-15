// POST /session — short-lived bearer tokens for the notification content extension.
//
// App Attest does not work in iOS app extensions (DCAppAttestService.generateKey fails there), so the app, which
// can attest, asks for a session token and shares it with its extension. The token is accepted only on /v1beta/*
// (`Authorization: Session <token>`), is rate-limited with the identity that requested it, and is stored only as a
// SHA-256 hash:  sess:<hex SHA-256 of the token> = { id, appId, expiresAt }  (KV TTL = lifetime).

import type { Identity } from "./auth.ts";
import { b64urlEncode, hex, sha256, utf8 } from "./encoding.ts";
import type { Deps, Env } from "./env.ts";
import { sessionTtlSeconds } from "./env.ts";
import { HttpError, json, log, parseJson } from "./http.ts";

export const MAX_SESSION_BODY = 1024;
/** base64url (no padding) of 32 bytes. */
export const SESSION_TOKEN_FORMAT = /^[A-Za-z0-9_-]{43}$/;

export interface SessionRecord {
  /** The identity the session acts as: an attested keyId, or "dev". */
  id: string;
  /** appId of that key (null for "dev"). */
  appId: string | null;
  /** ISO 8601 UTC, whole seconds. */
  expiresAt: string;
}

export async function sessionKey(token: string): Promise<string> {
  return `sess:${hex(await sha256(utf8(token)))}`;
}

/** ISO 8601 UTC without milliseconds, e.g. 2026-10-22T03:00:00Z (what Swift's .iso8601 decodes). */
export function isoSeconds(ms: number): string {
  return new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(/\.000Z$/, "Z");
}

export async function handleSession(body: Uint8Array, identity: Identity, env: Env, deps: Deps): Promise<Response> {
  const parsed = parseJson(body);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new HttpError(400, "invalid_request");

  const ttl = sessionTtlSeconds(env);
  const token = b64urlEncode(crypto.getRandomValues(new Uint8Array(32)));
  const expiresAt = isoSeconds((Math.floor(deps.now() / 1000) + ttl) * 1000);
  const record: SessionRecord = { id: identity.id, appId: identity.appId, expiresAt };
  try {
    await env.SS_KV.put(await sessionKey(token), JSON.stringify(record), { expirationTtl: ttl });
  } catch (e) {
    log("error", "session_write_failed", { error: String(e) });
    throw new HttpError(503, "server_busy");
  }
  log("info", "session_issued", { id: identity.id === "dev" ? "dev" : identity.id.slice(0, 12), expiresAt });
  return json(200, { token, expiresAt });
}

/** The live session for `token`, or null when it is unknown, expired or unreadable. */
export async function lookupSession(token: string, env: Env, now: number): Promise<SessionRecord | null> {
  if (!SESSION_TOKEN_FORMAT.test(token)) return null;
  const raw = await env.SS_KV.get(await sessionKey(token));
  if (raw === null) return null;
  try {
    const record = JSON.parse(raw) as SessionRecord;
    const expiresAt = Date.parse(record.expiresAt);
    if (typeof record.id !== "string" || !Number.isFinite(expiresAt) || expiresAt <= now) return null;
    return { id: record.id, appId: typeof record.appId === "string" ? record.appId : null, expiresAt: record.expiresAt };
  } catch {
    return null;
  }
}
