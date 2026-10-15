// Every minute: start the Live Activities whose triggerAt has come, via APNs push-to-start.
//
// For each minute m in [now − 2 min, now] the `due:<m>:` index is listed; each entry is re-checked against the
// device's current registration (the index may be stale: events get moved or deleted), so only an event that still
// exists with a triggerAt inside minute m, and at or before now, is sent. Per (eventID, triggerAt):
//   sent:  exists → never again;  claim: exists → another run is sending it right now.
// The claim (TTL 120 s) is written before calling APNs, becomes the sent marker on 200, and is deleted on any
// other outcome so the next minute retries until minute m leaves the window. A token APNs rejects (410, or 400
// BadDeviceToken) is recorded in `p2sdead:<deviceID>`; the cron never rewrites the registration itself, so it
// cannot overwrite a newer upload, and a registration whose token equals the dead one is skipped.
//
// Remaining race: KV is eventually consistent, so two overlapping runs in different locations may not see each
// other's claim or sent marker yet and both send (rare). A Durable Object per device would make it strict.

import { apnsExpiration, apnsHost, buildPayload, payloadTooLarge, sendPush } from "./apns.ts";
import type { Deps, Env } from "./env.ts";
import { log } from "./http.ts";
import { apnsJwt, invalidateApnsJwt } from "./jwt.ts";
import type { Registration, StoredEvent } from "./registration.ts";
import {
  REGISTRATION_TTL_SECONDS,
  SENT_TTL_SECONDS,
  claimKey,
  deadTokenKey,
  eventHash,
  minuteStamp,
  parseDueKey,
  parseRegistration,
  registrationKey,
  sentKey,
} from "./registration.ts";

export const SEND_CONCURRENCY = 10;
const CLAIM_TTL_SECONDS = 120;
const VALID_TOKEN = /^[0-9A-Fa-f]{1,200}$/;

export interface CronSummary {
  indexed: number;
  sent: number;
  failed: number;
  tokensInvalidated: number;
}

interface DeviceState {
  registration: Registration;
  /** eventHash → the registration's events with that eventID */
  byHash: Map<string, StoredEvent[]>;
  /** The token APNs last rejected for this device (p2sdead:), if any. */
  deadToken: string | null;
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

async function loadDevice(env: Env, deviceID: string): Promise<DeviceState | null> {
  const [raw, dead] = await Promise.all([env.SS_KV.get(registrationKey(deviceID)), env.SS_KV.get(deadTokenKey(deviceID))]);
  const registration = parseRegistration(raw);
  if (!registration) return null;
  const byHash = new Map<string, StoredEvent[]>();
  for (const event of registration.events) {
    const hash = await eventHash(event.eventID);
    byHash.set(hash, [...(byHash.get(hash) ?? []), event]);
  }
  return { registration, byHash, deadToken: dead };
}

/** Runs `fn` over `items` with at most `limit` in flight. */
async function forEachLimited<T>(items: T[], limit: number, fn: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const worker = async () => {
    while (next < items.length) await fn(items[next++]!);
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
}

export async function runCron(env: Env, deps: Deps): Promise<CronSummary> {
  const summary: CronSummary = { indexed: 0, sent: 0, failed: 0, tokensInvalidated: 0 };
  const host = apnsHost(env);
  if (!host) {
    log("error", "server_misconfigured", { reason: 'APNS_ENV must be "sandbox" or "production"' });
    return summary;
  }
  if (!env.APNS_KEY_ID?.trim() || !env.APNS_TEAM_ID?.trim() || !env.APNS_PRIVATE_KEY) {
    log("error", "server_misconfigured", { reason: "APNS_KEY_ID, APNS_TEAM_ID and APNS_PRIVATE_KEY must be set" });
    return summary;
  }
  const now = deps.now();
  const nowMinute = Math.floor(now / 60_000);

  // Nothing in a later minute can be due (sends happen at or after triggerAt), so the window ends at now.
  const due: { name: string; minute: number }[] = [];
  for (let minute = nowMinute - 2; minute <= nowMinute; minute++) {
    for (const name of await listAll(env, `due:${minuteStamp(minute * 60_000)}:`)) due.push({ name, minute });
  }
  summary.indexed = due.length;

  const devices = new Map<string, Promise<DeviceState | null>>();
  const deadThisRun = new Map<string, string>(); // deviceID → token rejected during this run
  let jwt: Promise<string> | null = null; // one provider token per run, minted lazily

  await forEachLimited(due, SEND_CONCURRENCY, async ({ name, minute }) => {
    const entry = parseDueKey(name);
    if (!entry) return;
    let claim: string | null = null;
    try {
      if (!devices.has(entry.deviceID)) devices.set(entry.deviceID, loadDevice(env, entry.deviceID));
      const device = await devices.get(entry.deviceID)!;
      if (!device) return; // registration expired or never stored

      const event = (device.byHash.get(entry.hash) ?? []).find((e) => Math.floor(Date.parse(e.triggerAt) / 60_000) === minute);
      if (!event) return; // deleted, or moved to another minute
      const triggerAt = Date.parse(event.triggerAt);
      if (triggerAt > now) return; // a later run sends it

      const token = device.registration.token;
      if (!token || !VALID_TOKEN.test(token) || token === device.deadToken || token === deadThisRun.get(entry.deviceID)) return;

      const marker = sentKey(entry.deviceID, entry.hash, triggerAt);
      const claimName = claimKey(entry.deviceID, entry.hash, triggerAt);
      const [sent, claimed] = await Promise.all([env.SS_KV.get(marker), env.SS_KV.get(claimName)]);
      if (sent !== null || claimed !== null) return;

      const payload = buildPayload(event, now);
      if (payloadTooLarge(payload)) {
        log("error", "apns_payload_too_large", { deviceID: entry.deviceID });
        return;
      }

      await env.SS_KV.put(claimName, "1", { expirationTtl: CLAIM_TTL_SECONDS });
      claim = claimName;
      jwt ??= apnsJwt(env, deps);
      const result = await sendPush(env, deps, host, token, await jwt, payload, apnsExpiration(event));

      if (result.status === 200) {
        summary.sent++;
        claim = null; // delivered: the claim keeps guarding until the sent marker is safely written
        await env.SS_KV.put(marker, "1", { expirationTtl: SENT_TTL_SECONDS });
        claim = claimName; // marker written: the claim is no longer needed
        log("info", "push_to_start_sent", { deviceID: entry.deviceID, apnsId: result.apnsId });
      } else if (result.status === 410 || (result.status === 400 && result.reason === "BadDeviceToken")) {
        summary.failed++;
        summary.tokensInvalidated++;
        deadThisRun.set(entry.deviceID, token);
        await env.SS_KV.put(deadTokenKey(entry.deviceID), token, { expirationTtl: REGISTRATION_TTL_SECONDS });
        log("warn", "push_token_invalid", { deviceID: entry.deviceID, status: result.status, reason: result.reason });
      } else {
        summary.failed++;
        log("error", "apns_rejected", { deviceID: entry.deviceID, status: result.status, reason: result.reason });
        if (result.status === 403 && (result.reason === "ExpiredProviderToken" || result.reason === "InvalidProviderToken")) {
          await invalidateApnsJwt(env);
        }
      }
    } catch (e) {
      // One bad entry (KV error, network failure, unreadable key) never stops the rest of the run.
      summary.failed++;
      log("error", "push_to_start_failed", { deviceID: entry.deviceID, error: e instanceof Error ? `${e.name}: ${e.message}` : String(e) });
    } finally {
      // After a 200 the sent marker guards the event (if writing it failed, the claim stays until its TTL);
      // on any other outcome the claim goes so the next minute retries.
      if (claim) await env.SS_KV.delete(claim).catch((e: unknown) => log("warn", "claim_delete_failed", { error: String(e) }));
    }
  });
  return summary;
}
