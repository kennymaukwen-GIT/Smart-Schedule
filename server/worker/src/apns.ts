// APNs push-to-start for iOS 18 Live Activities (HTTP/2 provider API, token-based auth).

import { utf8Length } from "./encoding.ts";
import type { Deps, Env } from "./env.ts";
import type { StoredEvent } from "./registration.ts";

export const MAX_PAYLOAD_BYTES = 4096;
export const ATTRIBUTES_TYPE = "ScheduleActivityAttributes";

export function apnsHost(env: Env): string | null {
  if (env.APNS_ENV === "production") return "api.push.apple.com";
  if (env.APNS_ENV === "sandbox") return "api.sandbox.push.apple.com";
  return null;
}

/**
 * The push-to-start payload. `attributes` and `content-state` are the client's JSON spliced in verbatim (the
 * registration route already checked each is a single JSON object), so dates stay exactly as Swift's default
 * JSONEncoder wrote them (seconds since 2001-01-01) and no number is re-serialized.
 */
export function buildPayload(event: StoredEvent, nowMs: number): string {
  const staleDate = Math.floor(Date.parse(event.eventStart) / 1000);
  return (
    `{"aps":{` +
    `"timestamp":${Math.floor(nowMs / 1000)},` +
    `"event":"start",` +
    `"attributes-type":${JSON.stringify(ATTRIBUTES_TYPE)},` +
    `"attributes":${event.attributesJSON.trim()},` +
    `"content-state":${event.contentStateJSON.trim()},` +
    `"stale-date":${staleDate},` +
    `"alert":{"title":${JSON.stringify(event.title)},"body":{"loc-key":"Starts in %@ min","loc-args":[${JSON.stringify(String(event.leadTime))}]}}` +
    `}}`
  );
}

export function payloadTooLarge(payload: string): boolean {
  return utf8Length(payload) > MAX_PAYLOAD_BYTES;
}

export interface ApnsResult {
  status: number;
  /** APNs error reason, e.g. "BadDeviceToken", "Unregistered" (null on success). */
  reason: string | null;
  apnsId: string | null;
}

/** APNs keeps a push for an offline device until the event starts, then drops it (never 0 = "deliver once"). */
export function apnsExpiration(event: StoredEvent): number {
  return Math.max(1, Math.floor(Date.parse(event.eventStart) / 1000));
}

export function apnsRequest(env: Env, host: string, deviceToken: string, jwt: string, payload: string, expiration: number): { url: string; init: RequestInit } {
  return {
    url: `https://${host}/3/device/${deviceToken}`,
    init: {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-push-type": "liveactivity",
        "apns-topic": `${env.APNS_BUNDLE_ID || "com.smartschedule.app"}.push-type.liveactivity`,
        "apns-priority": "10",
        "apns-expiration": String(expiration),
        "content-type": "application/json",
      },
      body: payload,
    },
  };
}

export async function sendPush(
  env: Env,
  deps: Deps,
  host: string,
  deviceToken: string,
  jwt: string,
  payload: string,
  expiration: number,
): Promise<ApnsResult> {
  const { url, init } = apnsRequest(env, host, deviceToken, jwt, payload, expiration);
  const response = await deps.fetch(url, init);
  const apnsId = response.headers.get("apns-id");
  if (response.status === 200) {
    await response.body?.cancel();
    return { status: 200, reason: null, apnsId };
  }
  let reason: string | null = null;
  try {
    const body = (await response.json()) as { reason?: unknown };
    if (typeof body.reason === "string") reason = body.reason;
  } catch {
    // no JSON body
  }
  return { status: response.status, reason, apnsId };
}
