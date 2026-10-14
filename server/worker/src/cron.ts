// Every minute: start the Live Activities whose triggerAt has come, via APNs push-to-start.
//
// For each minute m in [now − 2 min, now + 1 min] the `due:<m>:` index is listed; each entry is re-checked against
// the device's current registration (the index may be stale: events get moved or deleted), so only an event that
// still exists with a triggerAt inside minute m is sent, at most once per (eventID, triggerAt) thanks to the
// `sent:` marker. Failed sends are retried by the following runs until the minute leaves the window.

import { apnsHost, buildPayload, payloadTooLarge, sendPush } from "./apns.ts";
import type { Deps, Env } from "./env.ts";
import { ConfigError } from "./env.ts";
import { log } from "./http.ts";
import { apnsJwt, invalidateApnsJwt } from "./jwt.ts";
import type { Registration } from "./registration.ts";
import {
  REGISTRATION_TTL_SECONDS,
  SENT_TTL_SECONDS,
  minuteStamp,
  parseDueKey,
  parseRegistration,
  registrationKey,
  sentKey,
} from "./registration.ts";

const SEND_AHEAD_MS = 60_000;
const VALID_TOKEN = /^[0-9A-Fa-f]{1,200}$/;

export interface CronSummary {
  indexed: number;
  sent: number;
  failed: number;
  tokensInvalidated: number;
}

async function listAll(env: Env, prefix: string): Promise<string[]> {
  const names: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.SS_KV.list(cursor ? { prefix, cursor } : { prefix });
    for (const k of page.keys) names.push(k.name);
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return names;
}

/** Nulls the token after APNs reported it invalid — only if the stored registration still carries that token. */
async function invalidateToken(env: Env, deviceID: string, badToken: string, now: number): Promise<Registration | null> {
  const fresh = parseRegistration(await env.SS_KV.get(registrationKey(deviceID)));
  if (!fresh || fresh.token !== badToken) return fresh;
  const updated: Registration = { ...fresh, token: null, tokenInvalidAt: new Date(now).toISOString() };
  await env.SS_KV.put(registrationKey(deviceID), JSON.stringify(updated), { expirationTtl: REGISTRATION_TTL_SECONDS });
  return updated;
}

export async function runCron(env: Env, deps: Deps): Promise<CronSummary> {
  const summary: CronSummary = { indexed: 0, sent: 0, failed: 0, tokensInvalidated: 0 };
  const host = apnsHost(env);
  if (!host) {
    log("error", "server_misconfigured", { reason: 'APNS_ENV must be "sandbox" or "production"' });
    return summary;
  }
  const now = deps.now();
  const nowMinute = Math.floor(now / 60_000);
  const registrations = new Map<string, Registration | null>();

  for (let minute = nowMinute - 2; minute <= nowMinute + 1; minute++) {
    const names = await listAll(env, `due:${minuteStamp(minute * 60_000)}:`);
    summary.indexed += names.length;

    for (const name of names) {
      const due = parseDueKey(name);
      if (!due) continue;

      if (!registrations.has(due.deviceID)) {
        registrations.set(due.deviceID, parseRegistration(await env.SS_KV.get(registrationKey(due.deviceID))));
      }
      const registration = registrations.get(due.deviceID);
      if (!registration) continue; // expired or never stored

      // The event must still exist with a triggerAt inside this minute; otherwise it was deleted or moved.
      const event = registration.events.find(
        (e) => e.eventID === due.eventID && Math.floor(Date.parse(e.triggerAt) / 60_000) === minute,
      );
      if (!event) continue;
      const triggerAt = Date.parse(event.triggerAt);
      if (triggerAt > now + SEND_AHEAD_MS) continue; // a later run sends it

      const token = registration.token;
      if (!token || !VALID_TOKEN.test(token)) continue;

      const marker = sentKey(due.deviceID, event.eventID, triggerAt);
      if ((await env.SS_KV.get(marker)) !== null) continue;

      const payload = buildPayload(event, now);
      if (payloadTooLarge(payload)) {
        log("error", "apns_payload_too_large", { deviceID: due.deviceID, eventID: event.eventID });
        continue;
      }

      let jwt: string;
      try {
        jwt = await apnsJwt(env, deps);
      } catch (e) {
        if (e instanceof ConfigError) {
          log("error", "server_misconfigured", { reason: e.message });
          return summary;
        }
        throw e;
      }

      let result;
      try {
        result = await sendPush(env, deps, host, token, jwt, payload);
      } catch (e) {
        summary.failed++;
        log("error", "apns_unreachable", { deviceID: due.deviceID, eventID: event.eventID, error: String(e) });
        continue;
      }

      if (result.status === 200) {
        await env.SS_KV.put(marker, "1", { expirationTtl: SENT_TTL_SECONDS });
        summary.sent++;
        log("info", "push_to_start_sent", { deviceID: due.deviceID, eventID: event.eventID, apnsId: result.apnsId });
      } else if (result.status === 410 || (result.status === 400 && result.reason === "BadDeviceToken")) {
        summary.failed++;
        summary.tokensInvalidated++;
        log("warn", "push_token_invalid", { deviceID: due.deviceID, status: result.status, reason: result.reason });
        registrations.set(due.deviceID, await invalidateToken(env, due.deviceID, token, now));
      } else {
        summary.failed++;
        log("error", "apns_rejected", { deviceID: due.deviceID, eventID: event.eventID, status: result.status, reason: result.reason });
        if (result.status === 403 && (result.reason === "ExpiredProviderToken" || result.reason === "InvalidProviderToken")) {
          await invalidateApnsJwt(env);
        }
      }
    }
  }
  return summary;
}
