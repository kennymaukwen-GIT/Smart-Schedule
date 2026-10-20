// POST /v1/departure/routes — 「該出發了」: when to leave and which way to go, from Google's Routes API (computeRoutes).
//
// The app sends where from (its location or the words the user typed), where to (the event's place) and when the user
// must be there; the Worker asks Google with the server's key and answers with the time to leave, the time of arrival
// and Google's route. Nothing about the trip is logged or kept: no address, coordinates or route, only counts.
//
// Free use only (the owner never pays Google). Every limit is checked and reserved in one Durable Object
// (src/ledger.ts) BEFORE Google is called, so requests running at the same time cannot all pass the same check:
//   • for everyone: Google calls per pricing tier (SKU) and UTC day, at most DEPARTURE_DAILY_<SKU>. Both Worker
//     environments together × 32 days (a Google month, which starts at midnight US Pacific time, touches 32 UTC days)
//     stay within 80 % of the tier's monthly free calls. A request reserves the most calls it can make;
//   • per user (attested key): DEPARTURE_WEEKLY_PLANS new plans per week, the week starting on the user's Monday;
//     a plan's rechecks (same destination and arrival time; the start and the way to travel may change) are free,
//     up to DEPARTURE_PLAN_RECHECKS per plan; and at most DEPARTURE_USER_DAILY_CALLS Google calls a day whatever
//     the outcome (a place Google can't find is billed too).
// Not in the countries DEPARTURE_BLOCKED_COUNTRIES lists, nor where Cloudflare can't tell the country (by the
// request's IP; the app also checks on the iPhone).

import type { Identity } from "./auth.ts";
import { b64urlEncode, hex, sha256, utf8 } from "./encoding.ts";
import type { Deps, Env } from "./env.ts";
import { HttpError, json, log, parseJson } from "./http.ts";
import type { ReserveInput, ReserveResult, SettleInput } from "./ledger.ts";

export const ROUTES_URL = "https://routes.googleapis.com/directions/v2:computeRoutes";
export const MAX_DEPARTURE_BODY = 4096;

/** How the user travels: the app's choice, mapped to one Google travel mode and routing preference each. */
export type Mode = "transit" | "drive" | "walk" | "two_wheeler";
/** Google's pricing tiers for Compute Routes (Essentials, Pro, Enterprise), each with its own monthly free calls. */
export type Sku = "essentials" | "pro" | "enterprise";

export const MODES: readonly Mode[] = ["transit", "drive", "walk", "two_wheeler"];

/** Which tier each mode's request is billed at (see README: Routes API 計價). */
export const MODE_SKU: Readonly<Record<Mode, Sku>> = {
  transit: "essentials",
  walk: "essentials",
  drive: "pro",
  two_wheeler: "enterprise",
};

/**
 * The most Google calls one request makes: transit asks for the arrival time, and once more for "leave now" when that
 * is already too late; driving and two-wheeler have no arrive-by, so the departure time is solved in up to 3 calls.
 */
export const MAX_CALLS: Readonly<Record<Mode, number>> = { transit: 2, drive: 3, walk: 1, two_wheeler: 3 };

/** The owner's decision (2026-10-20): not in the United Kingdom. */
export const DEFAULT_BLOCKED_COUNTRIES = ["GB"];

/** Each tier's monthly free calls (Google Maps Platform pricing, Compute Routes Essentials / Pro / Enterprise). */
export const FREE_MONTHLY_CALLS: Readonly<Record<Sku, number>> = { essentials: 10_000, pro: 5_000, enterprise: 1_000 };

/** A Google month (midnight to midnight US Pacific time) touches at most 32 UTC days. */
export const DAYS_PER_GOOGLE_MONTH = 32;

/** 80 % of each tier's monthly free calls ÷ 32 days: a month never reaches the free calls. */
export const DEFAULT_DAILY_CAPS: Readonly<Record<Sku, number>> = { essentials: 250, pro: 125, enterprise: 25 };

/**
 * Exactly the fields the app shows (fixed here: the app cannot ask for more). No toll, fuel or traffic-on-polyline
 * fields: asking for them would move the request to a more expensive tier.
 */
export const FIELD_MASK = [
  "routes.duration",
  "routes.staticDuration",
  "routes.distanceMeters",
  "routes.description",
  "routes.warnings",
  "routes.localizedValues",
  "routes.legs.steps.travelMode",
  "routes.legs.steps.staticDuration",
  "routes.legs.steps.distanceMeters",
  "routes.legs.steps.navigationInstruction",
  "routes.legs.steps.localizedValues",
  "routes.legs.steps.transitDetails",
  "routes.legs.stepsOverview",
  "geocodingResults",
  "fallbackInfo",
].join(",");

const MINUTE = 60_000;
const DAY_MS = 86_400_000;
const MAX_ADDRESS_LENGTH = 200;
/** Google plans transit up to 100 days ahead. */
const MAX_AHEAD_MS = 100 * DAY_MS;
const PLAN_TOKEN = /^[A-Za-z0-9_-]{43}$/;
const LANGUAGE = /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$/;
const REGION = /^[a-z]{2}$/;
/** A departure time this close to now is sent as "now" (no departureTime): Google refuses a past one except for transit. */
const NOW_SLACK_MS = MINUTE;
/** First guess for the solved departure: 30 minutes before the arrival. */
const FIRST_GUESS_MS = 30 * MINUTE;
/** The solved departure is final once a call confirms arriving at most 2 minutes early. */
const CONVERGED_MS = 2 * MINUTE;
/** When Google could not use live traffic (fallbackInfo), its duration is lengthened by this factor. */
const FALLBACK_FACTOR = 1.25;
const GOOGLE_TIMEOUT_MS = 10_000;
const KEYS = new Set(["mode", "origin", "destination", "arriveBy", "plan", "utcOffsetMinutes", "language", "region", "debugBuild"]);

export interface Point {
  lat: number;
  lng: number;
}

export type Place = { point: Point } | { address: string };

export interface DepartureRequest {
  mode: Mode;
  origin: Place;
  /** The event's place as the user wrote it. */
  destination: string;
  /** Epoch ms the user must be there by; null: leave now (how long does it take). */
  arriveBy: number | null;
  /** A plan's token: this request rechecks that plan. */
  plan: string | null;
  /** The user's UTC offset, for the week that starts on their Monday. */
  utcOffsetMinutes: number;
  language: string | null;
  region: string | null;
  /** Only Debug builds (Xcode) send it, inside the signed body. */
  debugBuild: boolean;
}

// ---------------------------------------------------------------------------------------------------------------------
// Request

function text(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.normalize("NFC").replace(/\s+/g, " ").trim();
  // No control characters (U+0000–U+001F, U+007F) left after the whitespace fold.
  if (!trimmed || [...trimmed].length > MAX_ADDRESS_LENGTH || /[\u0000-\u001f\u007f]/.test(trimmed)) return null;
  return trimmed;
}

function place(value: unknown, allowPoint: boolean): Place | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const fields = value as Record<string, unknown>;
  const keys = Object.keys(fields).sort().join(",");
  if (keys === "address") {
    const address = text(fields.address);
    return address ? { address } : null;
  }
  if (allowPoint && keys === "lat,lng") {
    const { lat, lng } = fields;
    if (typeof lat !== "number" || typeof lng !== "number" || !Number.isFinite(lat) || !Number.isFinite(lng)) return null;
    if (Math.abs(lat) > 90 || Math.abs(lng) > 180) return null;
    return { point: { lat, lng } };
  }
  return null;
}

/** ISO 8601 date-time with a zone (what Swift's `.iso8601` writes); epoch ms or null. */
function isoMs(value: unknown): number | null {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

/** The request, or null when anything is missing, unknown, out of range or malformed. */
export function parseDepartureRequest(value: unknown, now: number): DepartureRequest | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const fields = value as Record<string, unknown>;
  if (Object.keys(fields).some((key) => !KEYS.has(key))) return null;

  const mode = MODES.find((m) => m === fields.mode);
  const origin = place(fields.origin, true);
  const destination = place(fields.destination, false);
  if (!mode || !origin || !destination || !("address" in destination)) return null;

  let arriveBy: number | null = null;
  if (fields.arriveBy !== undefined && fields.arriveBy !== null) {
    arriveBy = isoMs(fields.arriveBy);
    if (arriveBy === null || arriveBy < now - MINUTE || arriveBy > now + MAX_AHEAD_MS) return null;
  }
  let plan: string | null = null;
  if (fields.plan !== undefined && fields.plan !== null) {
    if (typeof fields.plan !== "string" || !PLAN_TOKEN.test(fields.plan)) return null;
    plan = fields.plan;
  }
  const offset = fields.utcOffsetMinutes;
  if (typeof offset !== "number" || !Number.isInteger(offset) || offset < -720 || offset > 840) return null;
  let language: string | null = null;
  if (fields.language !== undefined && fields.language !== null) {
    if (typeof fields.language !== "string" || !LANGUAGE.test(fields.language)) return null;
    language = fields.language;
  }
  let region: string | null = null;
  if (fields.region !== undefined && fields.region !== null) {
    if (typeof fields.region !== "string" || !REGION.test(fields.region)) return null;
    region = fields.region;
  }
  if (fields.debugBuild !== undefined && typeof fields.debugBuild !== "boolean") return null;

  return {
    mode,
    origin,
    destination: destination.address,
    arriveBy,
    plan,
    utcOffsetMinutes: offset,
    language,
    region,
    debugBuild: fields.debugBuild === true,
  };
}

// ---------------------------------------------------------------------------------------------------------------------
// Configuration

function count(value: string | undefined, fallback: number): number {
  const n = Number(value?.trim());
  return value?.trim() && Number.isInteger(n) && n >= 0 ? n : fallback;
}

/** Country codes (ISO 3166-1 alpha-2, as Cloudflare's request.cf.country) where the feature is off. */
export function blockedCountries(env: Env): Set<string> {
  const list = (env.DEPARTURE_BLOCKED_COUNTRIES ?? "")
    .split(",")
    .map((s) => s.trim().toUpperCase())
    .filter(Boolean);
  return new Set(list.length ? list : DEFAULT_BLOCKED_COUNTRIES);
}

export function weeklyPlans(env: Env): number {
  return count(env.DEPARTURE_WEEKLY_PLANS, 2);
}

export function planRechecks(env: Env): number {
  return count(env.DEPARTURE_PLAN_RECHECKS, 5);
}

/** Google calls one identity may make per UTC day, whatever the outcome. */
export function userDailyCalls(env: Env): number {
  return count(env.DEPARTURE_USER_DAILY_CALLS, 30);
}

/** Calls per tier and UTC day; a cap below the tier's largest MAX_CALLS (0 included) turns the tier off. */
export function dailyCap(env: Env, sku: Sku): number {
  const raw = { essentials: env.DEPARTURE_DAILY_ESSENTIALS, pro: env.DEPARTURE_DAILY_PRO, enterprise: env.DEPARTURE_DAILY_ENTERPRISE }[sku];
  return count(raw, DEFAULT_DAILY_CAPS[sku]);
}

// ---------------------------------------------------------------------------------------------------------------------
// Region

/** request.cf.country could not name a country (omitted, "XX" for no data, "T1" for Tor). */
export const UNKNOWN_COUNTRY = "??";

/**
 * The country Cloudflare located the request in; UNKNOWN_COUNTRY when Cloudflare could not tell; null when the
 * request has no `cf` at all (not served by Cloudflare: tests).
 */
export function requestCountry(request: Request): string | null {
  const cf = (request as unknown as { cf?: { country?: unknown } }).cf;
  if (!cf) return null;
  const country = cf.country;
  return typeof country === "string" && /^[A-Z]{2}$/.test(country) && country !== "XX" ? country : UNKNOWN_COUNTRY;
}

/**
 * Off in the blocked countries and where the country is unknown. A Debug build (the owner's own, from Xcode) may test
 * there with a typed starting point only, so no location from a blocked country ever reaches Google.
 */
export function regionAllows(country: string | null, blocked: Set<string>, request: DepartureRequest): boolean {
  if (country === null || (country !== UNKNOWN_COUNTRY && !blocked.has(country))) return true;
  return request.debugBuild && "address" in request.origin;
}

// ---------------------------------------------------------------------------------------------------------------------
// Weeks, days and plans

/** The user's local Monday (YYYYMMDD) of the week containing `now`. */
export function weekOf(now: number, utcOffsetMinutes: number): string {
  const day = Math.floor((now + utcOffsetMinutes * MINUTE) / DAY_MS); // day 0 (1970-01-01) was a Thursday
  const monday = day - ((((day + 3) % 7) + 7) % 7);
  return new Date(monday * DAY_MS).toISOString().slice(0, 10).replace(/-/g, "");
}

/** Seconds until the user's next Monday 00:00. */
export function untilNextWeek(now: number, utcOffsetMinutes: number): number {
  const local = now + utcOffsetMinutes * MINUTE;
  const day = Math.floor(local / DAY_MS);
  const nextMonday = day - ((((day + 3) % 7) + 7) % 7) + 7;
  return Math.max(1, Math.ceil((nextMonday * DAY_MS - local) / 1000));
}

export function utcDay(now: number): string {
  return new Date(now).toISOString().slice(0, 10).replace(/-/g, "");
}

function untilNextUtcDay(now: number): number {
  return Math.max(1, Math.ceil(((Math.floor(now / DAY_MS) + 1) * DAY_MS - now) / 1000));
}

/** Where the ledger keeps a plan: hex SHA-256 of its token (only the iPhone has the token). */
export async function planHash(token: string): Promise<string> {
  return hex(await sha256(utf8(token)));
}

/**
 * Ties a plan to its trip without keeping the trip: SHA-256 of the token, the destination and the arrival time. Only
 * the iPhone has the token, so the stored value says nothing about where the user is going.
 */
export async function planBinding(token: string, destination: string, arriveBy: number | null): Promise<string> {
  const normalized = destination.normalize("NFC").replace(/\s+/g, " ").trim().toLowerCase();
  return hex(await sha256(utf8(`${token}\u0000${normalized}\u0000${arriveBy ?? "now"}`)));
}

/** A plan can be rechecked until 2 hours after the arrival (a "how long" plan: for 2 hours). */
export function planExpiry(arriveBy: number | null, now: number): number {
  return (arriveBy ?? now) + 2 * 3600_000;
}

// ---------------------------------------------------------------------------------------------------------------------
// Google

export type GoogleRoute = Record<string, unknown>;

export type Attempt =
  /** `fallback`: Google could not use the requested traffic model; `seconds` is already lengthened for it. */
  | { kind: "route"; route: GoogleRoute; seconds: number; fallback: boolean }
  | { kind: "no_route" }
  | { kind: "not_found"; place: "origin" | "destination" }
  /** Google answered 429: its own quota (the Google Cloud cap) is used up. */
  | { kind: "quota" }
  /** Unreachable, 5xx, or Google refused our key (401/403, or 400 with an API_KEY_* reason). */
  | { kind: "unavailable"; status: number | null };

/** The time a call asks about: leave now, leave at, or (transit only) arrive by. */
export type Timing = { leave: "now" } | { leave: number } | { arrive: number };

/** Seconds of a protobuf Duration as JSON ("1234s", "12.5s"), or null. */
export function durationSeconds(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const match = /^(\d+)(?:\.\d+)?s$/.exec(value);
  return match ? Number(match[1]) : null;
}

function isoSeconds(ms: number): string {
  return new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(/\.000Z$/, "Z");
}

function waypoint(p: Place): Record<string, unknown> {
  return "address" in p ? { address: p.address } : { location: { latLng: { latitude: p.point.lat, longitude: p.point.lng } } };
}

/** The computeRoutes body for one call: one route, no alternatives, no extra computations. */
export function googleRequestBody(request: DepartureRequest, timing: Timing): Record<string, unknown> {
  const body: Record<string, unknown> = {
    origin: waypoint(request.origin),
    destination: { address: request.destination },
    computeAlternativeRoutes: false,
  };
  switch (request.mode) {
    case "transit":
      body.travelMode = "TRANSIT";
      break;
    case "walk":
      body.travelMode = "WALK";
      break;
    case "drive":
      // Pessimistic: "longer than the actual travel time on most days", so the user is rarely late.
      body.travelMode = "DRIVE";
      body.routingPreference = "TRAFFIC_AWARE_OPTIMAL";
      body.trafficModel = "PESSIMISTIC";
      break;
    case "two_wheeler":
      // trafficModel is DRIVE only.
      body.travelMode = "TWO_WHEELER";
      body.routingPreference = "TRAFFIC_AWARE_OPTIMAL";
      break;
  }
  if ("arrive" in timing) body.arrivalTime = isoSeconds(timing.arrive);
  else if (timing.leave !== "now") body.departureTime = isoSeconds(timing.leave);
  if (request.language) body.languageCode = request.language;
  if (request.region) body.regionCode = request.region;
  return body;
}

function objectOf(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

function geocoderFailed(results: unknown, which: "origin" | "destination"): boolean {
  const status = objectOf(objectOf(objectOf(results)[which]).geocoderStatus);
  return typeof status.code === "number" && status.code !== 0;
}

/** Google refused the key itself: 400 INVALID_ARGUMENT with an ErrorInfo reason API_KEY_INVALID, API_KEY_EXPIRED, … */
export function keyRefused(body: unknown): boolean {
  const details = objectOf(objectOf(body).error).details;
  return Array.isArray(details) && details.some((d) => typeof objectOf(d).reason === "string" && String(objectOf(d).reason).startsWith("API_KEY_"));
}

/** What one computeRoutes answer means for the plan (pure: the status and the parsed JSON body). */
export function readGoogleAnswer(status: number, body: unknown): Attempt {
  if (status === 429) return { kind: "quota" };
  if (status === 401 || status === 403 || status >= 500) return { kind: "unavailable", status };
  if (status === 400 && keyRefused(body)) return { kind: "unavailable", status };
  if (status !== 200) return { kind: "no_route" }; // 400/404 about the trip: e.g. no scooter routing for this origin
  const answer = objectOf(body);
  const route = Array.isArray(answer.routes) ? (answer.routes[0] as GoogleRoute | undefined) : undefined;
  const seconds = durationSeconds(route?.duration);
  if (route && typeof route === "object" && seconds !== null) {
    // Without live traffic or the pessimistic model the duration is too short at busy times: allow 25 % more.
    const fallback = Object.keys(objectOf(answer.fallbackInfo)).length > 0;
    return { kind: "route", route, seconds: fallback ? Math.ceil(seconds * FALLBACK_FACTOR) : seconds, fallback };
  }
  if (geocoderFailed(answer.geocodingResults, "origin")) return { kind: "not_found", place: "origin" };
  if (geocoderFailed(answer.geocodingResults, "destination")) return { kind: "not_found", place: "destination" };
  return { kind: "no_route" };
}

/**
 * Whether Google billed a call that got this answer: everything but quota refusals, key refusals and server errors.
 * A call whose outcome is unknown (timeout, reset) counts as billed.
 */
export function billable(status: number | null, attempt: Attempt | null): boolean {
  if (status === null) return true;
  if (attempt?.kind === "quota" || attempt?.kind === "unavailable") return false;
  return true;
}

// ---------------------------------------------------------------------------------------------------------------------
// When to leave

export type Solved =
  /** `estimate`: Google did not confirm this exact departure (or had no live traffic); the app says it is an estimate. */
  | { kind: "ok"; departAt: number; arriveAt: number; late: boolean; estimate: boolean; route: GoogleRoute }
  | Exclude<Attempt, { kind: "route" }>;

/** Floors to the whole minute: the app says "leave at 15:48", never later than the solved time. */
function floorMinute(ms: number): number {
  return Math.floor(ms / MINUTE) * MINUTE;
}

function steps(route: GoogleRoute): Record<string, unknown>[] {
  const legs = Array.isArray(route.legs) ? (route.legs as unknown[]) : [];
  return legs.flatMap((leg) => {
    const list = objectOf(leg).steps;
    return Array.isArray(list) ? list.map(objectOf) : [];
  });
}

function stopTime(step: Record<string, unknown>, which: "departureTime" | "arrivalTime"): number | null {
  return isoMs(objectOf(objectOf(step.transitDetails).stopDetails)[which]);
}

/**
 * Leave and arrive times of a transit route: the first vehicle's departure minus the walk before it, and the last
 * vehicle's arrival plus the walk after it. Null for a route without a timed vehicle (walking only).
 */
export function transitTimes(route: GoogleRoute): { departAt: number; arriveAt: number } | null {
  const all = steps(route);
  const timed = all.map((step, index) => ({ step, index })).filter(({ step }) => step.travelMode === "TRANSIT");
  const first = timed[0];
  const last = timed[timed.length - 1];
  if (!first || !last) return null;
  const leave = stopTime(first.step, "departureTime");
  const arrive = stopTime(last.step, "arrivalTime");
  if (leave === null || arrive === null) return null;
  const walk = (from: number, to: number) =>
    all.slice(from, to).reduce((sum, step) => sum + (durationSeconds(step.staticDuration) ?? 0) * 1000, 0);
  return { departAt: leave - walk(0, first.index), arriveAt: arrive + walk(last.index + 1, all.length) };
}

type Call = (timing: Timing) => Promise<Attempt>;

/** Transit: Google plans by the arrival time itself; when that would mean leaving in the past, plan from now. */
export async function solveTransit(arriveBy: number | null, now: number, call: Call): Promise<Solved> {
  const fromNow = async (): Promise<Solved> => {
    const attempt = await call({ leave: "now" });
    if (attempt.kind !== "route") return attempt;
    const times = transitTimes(attempt.route) ?? { departAt: now, arriveAt: now + attempt.seconds * 1000 };
    return {
      kind: "ok",
      departAt: floorMinute(Math.max(now, times.departAt)),
      arriveAt: times.arriveAt,
      late: arriveBy !== null && times.arriveAt > arriveBy,
      estimate: false,
      route: attempt.route,
    };
  };
  if (arriveBy === null) return fromNow();
  const attempt = await call({ arrive: arriveBy });
  if (attempt.kind !== "route") return attempt;
  const times = transitTimes(attempt.route) ?? { departAt: arriveBy - attempt.seconds * 1000, arriveAt: arriveBy };
  if (times.departAt < now - NOW_SLACK_MS) return fromNow();
  return {
    kind: "ok",
    departAt: floorMinute(Math.max(now, times.departAt)),
    arriveAt: times.arriveAt,
    late: times.arriveAt > arriveBy,
    estimate: false,
    route: attempt.route,
  };
}

interface Sample {
  /** The departure asked about (epoch ms; `now` for "leave now"). */
  t: number;
  /** Duration in ms. */
  ms: number;
  route: GoogleRoute;
  fallback: boolean;
}

/**
 * The next departure to ask about, aiming at t + duration(t) = arriveBy: from the last two answers, the secant through
 * them (exact when the duration changes linearly with the departure time); from one answer, arriveBy − its duration.
 */
export function nextDeparture(samples: readonly Sample[], arriveBy: number): number {
  const b = samples[samples.length - 1]!;
  const a = samples[samples.length - 2];
  const fb = b.t + b.ms - arriveBy;
  if (a && a.t !== b.t) {
    const slope = (fb - (a.t + a.ms - arriveBy)) / (b.t - a.t);
    if (slope > 0.05) return b.t - fb / slope;
  }
  return arriveBy - b.ms;
}

/**
 * Driving and scooter: Google takes a departure time only, so the latest departure that still arrives by `arriveBy`
 * is searched for, asking at whole minutes, in at most `maxCalls` calls. The answer is always a departure Google
 * itself confirmed (asked about, and arriving in time), the latest such one. When no answer was in time, the last
 * call checks a time chosen 2 minutes on the safe side; if even that is late, the answer is an estimate (or "late"
 * when leaving now is already too late).
 */
export async function solveRoad(arriveBy: number | null, now: number, call: Call, maxCalls: number): Promise<Solved> {
  const near = (t: number) => t <= now + NOW_SLACK_MS;
  if (arriveBy === null) {
    const attempt = await call({ leave: "now" });
    if (attempt.kind !== "route") return attempt;
    return { kind: "ok", departAt: floorMinute(now), arriveAt: now + attempt.seconds * 1000, late: false, estimate: attempt.fallback, route: attempt.route };
  }

  const samples: Sample[] = [];
  const onTime = (s: Sample) => s.t + s.ms <= arriveBy;
  let failure: Solved | null = null;
  let t = Math.max(now, floorMinute(arriveBy - FIRST_GUESS_MS));
  for (let calls = 0; calls < maxCalls; calls++) {
    const attempt = await call(near(t) ? { leave: "now" } : { leave: t });
    if (attempt.kind !== "route") {
      failure = attempt;
      break;
    }
    const sample: Sample = { t: near(t) ? now : t, ms: attempt.seconds * 1000, route: attempt.route, fallback: attempt.fallback };
    samples.push(sample);
    const slack = arriveBy - (sample.t + sample.ms);
    if (slack >= 0 && slack <= CONVERGED_MS) break; // in time, at most 2 minutes early
    if (slack < 0 && near(sample.t)) break; // late even leaving now
    const left = maxCalls - calls - 1;
    if (left === 0) break;
    let next = nextDeparture(samples, arriveBy);
    if (left === 1 && !samples.some(onTime)) next -= CONVERGED_MS; // the last call should land in time
    next = Math.min(floorMinute(next), floorMinute(arriveBy));
    if (next <= now + NOW_SLACK_MS) next = now;
    if (samples.some((s) => Math.abs(s.t - next) < MINUTE)) break; // already asked
    t = next;
  }

  const confirmed = samples.filter(onTime).sort((x, y) => y.t - x.t)[0];
  if (confirmed) {
    return { kind: "ok", departAt: floorMinute(confirmed.t), arriveAt: confirmed.t + confirmed.ms, late: false, estimate: confirmed.fallback, route: confirmed.route };
  }
  const leavingNow = samples.find((s) => s.t === now);
  if (leavingNow) {
    return { kind: "ok", departAt: floorMinute(now), arriveAt: now + leavingNow.ms, late: true, estimate: leavingNow.fallback, route: leavingNow.route };
  }
  const last = samples[samples.length - 1];
  if (!last) return failure ?? { kind: "no_route" };
  // No answer was in time and none was "now": go by the trend, with the last miss again as margin.
  const overshoot = last.t + last.ms - arriveBy;
  const departAt = floorMinute(Math.max(now, nextDeparture(samples, arriveBy) - Math.max(5 * MINUTE, overshoot)));
  return { kind: "ok", departAt, arriveAt: arriveBy, late: false, estimate: true, route: last.route };
}

/** Walking takes the same time whenever you leave: one call. */
export async function solveWalk(arriveBy: number | null, now: number, call: Call): Promise<Solved> {
  const attempt = await call({ leave: "now" });
  if (attempt.kind !== "route") return attempt;
  const duration = attempt.seconds * 1000;
  if (arriveBy === null) return { kind: "ok", departAt: floorMinute(now), arriveAt: now + duration, late: false, estimate: false, route: attempt.route };
  const implied = arriveBy - duration;
  if (implied < now) return { kind: "ok", departAt: floorMinute(now), arriveAt: now + duration, late: true, estimate: false, route: attempt.route };
  const departAt = floorMinute(implied);
  return { kind: "ok", departAt, arriveAt: departAt + duration, late: false, estimate: false, route: attempt.route };
}

export function solve(request: DepartureRequest, now: number, call: Call): Promise<Solved> {
  switch (request.mode) {
    case "transit":
      return solveTransit(request.arriveBy, now, call);
    case "walk":
      return solveWalk(request.arriveBy, now, call);
    case "drive":
    case "two_wheeler":
      return solveRoad(request.arriveBy, now, call, MAX_CALLS[request.mode]);
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Ledger (src/ledger.ts)

async function ledger<T>(env: Env, op: "reserve" | "settle", body: ReserveInput | SettleInput): Promise<T> {
  const namespace = env.SS_DEPARTURE_LEDGER;
  if (!namespace) {
    log("error", "server_misconfigured", { reason: "SS_DEPARTURE_LEDGER Durable Object binding is missing" });
    throw new HttpError(500, "server_misconfigured");
  }
  let response: Response;
  try {
    response = await namespace.get(namespace.idFromName("ledger")).fetch(`https://ledger/${op}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (e) {
    log("error", "departure_ledger_failed", { op, error: e instanceof Error ? e.name : "error" });
    throw new HttpError(503, "server_busy", { "retry-after": "1" });
  }
  if (!response.ok) {
    log("error", "departure_ledger_failed", { op, status: response.status });
    throw new HttpError(503, "server_busy", { "retry-after": "1" });
  }
  return (await response.json()) as T;
}

// ---------------------------------------------------------------------------------------------------------------------
// Handler

export async function handleDepartureRoutes(request: Request, body: Uint8Array, identity: Identity, env: Env, deps: Deps): Promise<Response> {
  const now = deps.now();
  const trip = parseDepartureRequest(parseJson(body), now);
  if (!trip) throw new HttpError(400, "invalid_request");

  const country = requestCountry(request);
  if (!regionAllows(country, blockedCountries(env), trip)) {
    log("info", "departure_region_refused", { country });
    throw new HttpError(403, "region_unavailable");
  }
  const apiKey = env.GOOGLE_ROUTES_API_KEY?.trim();
  if (!apiKey) {
    log("error", "server_misconfigured", { reason: "GOOGLE_ROUTES_API_KEY secret is not set" });
    throw new HttpError(500, "server_misconfigured");
  }

  // Reserve everything this request may use before calling Google.
  const sku = MODE_SKU[trip.mode];
  const day = utcDay(now);
  const week = weekOf(now, trip.utcOffsetMinutes);
  const reserved = MAX_CALLS[trip.mode];
  const allowance = weeklyPlans(env);
  const recheck = trip.plan
    ? { hash: await planHash(trip.plan), binding: await planBinding(trip.plan, trip.destination, trip.arriveBy), maxRechecks: planRechecks(env) }
    : null;
  const reservation = await ledger<ReserveResult>(env, "reserve", {
    id: identity.id,
    sku,
    day,
    week,
    calls: reserved,
    tierCap: dailyCap(env, sku),
    userDailyCalls: userDailyCalls(env),
    weeklyPlans: allowance,
    recheck,
    now,
  });
  if (!reservation.ok) {
    log("info", "departure_refused", { reason: reservation.reason, sku });
    switch (reservation.reason) {
      case "invalid_plan":
        throw new HttpError(403, "invalid_plan");
      case "recheck_limit":
        throw new HttpError(429, "recheck_limit");
      case "weekly_limit":
        throw new HttpError(429, "weekly_limit", { "retry-after": String(untilNextWeek(now, trip.utcOffsetMinutes)) });
      case "capacity_reached":
      case "user_daily_limit":
        throw new HttpError(429, reservation.reason, { "retry-after": String(untilNextUtcDay(now)) });
    }
  }

  let made = 0;
  let unbilled = 0;
  const call: Call = async (timing) => {
    made++;
    let response: Response;
    try {
      response = await deps.fetch(ROUTES_URL, {
        method: "POST",
        headers: { "content-type": "application/json", "x-goog-api-key": apiKey, "x-goog-fieldmask": FIELD_MASK },
        body: JSON.stringify(googleRequestBody(trip, timing)),
        redirect: "manual",
        signal: AbortSignal.timeout(GOOGLE_TIMEOUT_MS),
      });
    } catch (e) {
      // Google may have received and billed it: counted as billed.
      log("error", "routes_unreachable", { error: e instanceof Error ? e.name : "error" });
      return { kind: "unavailable", status: null };
    }
    let parsed: unknown;
    try {
      parsed = parseJson(new Uint8Array(await response.arrayBuffer()));
    } catch (e) {
      log("error", "routes_unreachable", { error: e instanceof Error ? e.name : "error" });
      return { kind: "unavailable", status: null };
    }
    const attempt = readGoogleAnswer(response.status, parsed);
    if (!billable(response.status, attempt)) unbilled++;
    if (response.status !== 200) {
      log("warn", "routes_refused", { status: response.status, key: attempt.kind === "unavailable" && response.status === 400 ? "refused" : undefined });
    }
    return attempt;
  };

  let solved: Solved;
  try {
    solved = await solve(trip, now, call);
  } catch (e) {
    // Unexpected: give back only the calls never made; the reservation of the rest stays.
    await ledger(env, "settle", { id: identity.id, sku, day, week, unbilled: reserved - made, releasePlan: false, releaseRecheck: null, createPlan: null }).catch(() => {});
    throw e;
  }

  const ok = solved.kind === "ok";
  const failed = solved.kind === "quota" || solved.kind === "unavailable";
  const token = !recheck && ok ? b64urlEncode(crypto.getRandomValues(new Uint8Array(32))) : null;
  let plansUsed = reservation.plansUsed;
  let planToken: string | null = recheck ? trip.plan : token;
  try {
    const settled = await ledger<{ plansUsed: number }>(env, "settle", {
      id: identity.id,
      sku,
      day,
      week,
      unbilled: reserved - made + unbilled,
      releasePlan: !recheck && !ok, // only a plan that gave the user a route counts
      releaseRecheck: recheck && failed ? recheck.hash : null,
      createPlan: token
        ? { hash: await planHash(token), entry: { id: identity.id, binding: await planBinding(token, trip.destination, trip.arriveBy), rechecks: 0, expiresAt: planExpiry(trip.arriveBy, now) } }
        : null,
    });
    plansUsed = settled.plansUsed;
  } catch (e) {
    // The reservation stays counted (the safe side); without a stored plan, its rechecks would count as new plans.
    log("warn", "departure_settle_failed", { error: e instanceof HttpError ? e.code : "error" });
    if (token) planToken = null;
  }

  log("info", "departure_route", {
    mode: trip.mode,
    sku,
    calls: made,
    billed: made - unbilled,
    result: solved.kind,
    late: solved.kind === "ok" ? solved.late : null,
    estimate: solved.kind === "ok" ? solved.estimate : null,
    recheck: recheck !== null,
  });

  if (solved.kind === "quota") throw new HttpError(429, "capacity_reached", { "retry-after": String(untilNextUtcDay(now)) });
  if (solved.kind === "unavailable") throw new HttpError(502, "upstream_unavailable");
  const plansLeft = Math.max(0, allowance - plansUsed);
  if (solved.kind === "no_route") return json(200, { result: "no_route", plansLeft });
  if (solved.kind === "not_found") return json(200, { result: "place_not_found", place: solved.place, plansLeft });

  return json(200, {
    result: "ok",
    mode: trip.mode,
    departAt: isoSeconds(solved.departAt),
    arriveAt: isoSeconds(solved.arriveAt),
    late: solved.late,
    estimate: solved.estimate,
    route: solved.route,
    plan: planToken,
    plansLeft,
  });
}
