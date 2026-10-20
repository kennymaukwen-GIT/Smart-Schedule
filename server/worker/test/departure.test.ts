import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Attempt, DepartureRequest, GoogleRoute, Timing } from "../src/departure.ts";
import {
  DAYS_PER_GOOGLE_MONTH,
  DEFAULT_DAILY_CAPS,
  FIELD_MASK,
  FREE_MONTHLY_CALLS,
  MAX_CALLS,
  MODE_SKU,
  ROUTES_URL,
  UNKNOWN_COUNTRY,
  billable,
  blockedCountries,
  dailyCap,
  durationSeconds,
  googleRequestBody,
  keyRefused,
  parseDepartureRequest,
  planBinding,
  planExpiry,
  readGoogleAnswer,
  regionAllows,
  requestCountry,
  solveRoad,
  solveTransit,
  solveWalk,
  transitTimes,
  untilNextWeek,
  untilPacificMidnight,
  userDailyCalls,
  userTierCalls,
  weekOf,
  weeklyPlans,
} from "../src/departure.ts";
import type { Env } from "../src/env.ts";
import { reserve, settle, sweep } from "../src/ledger.ts";
import type { ReserveInput } from "../src/ledger.ts";
import type { FetchCall, Harness } from "./helpers/harness.ts";
import { START, jsonOf, makeHarness } from "./helpers/harness.ts";
import { MemorySyncKv } from "./helpers/ledger.ts";

const MIN = 60_000;
const iso = (ms: number) => new Date(ms).toISOString().replace(/\.000Z$/, "Z");

function trip(fields: Partial<DepartureRequest> = {}): DepartureRequest {
  return {
    mode: "transit",
    origin: { address: "台北車站" },
    destination: "台北101",
    arriveBy: START + 60 * MIN,
    plan: null,
    utcOffsetMinutes: 480,
    language: "zh-TW",
    region: "tw",
    debugBuild: false,
    ...fields,
  };
}

/** A transit route: walk 4 min, MRT 15:54 → 16:10, walk 5 min. */
function transitRoute(depart: number, arrive: number, walkBefore = 240, walkAfter = 300): GoogleRoute {
  return {
    duration: `${(arrive - depart) / 1000 + walkBefore + walkAfter}s`,
    legs: [
      {
        steps: [
          { travelMode: "WALK", staticDuration: `${walkBefore}s` },
          { travelMode: "TRANSIT", staticDuration: `${(arrive - depart) / 1000}s`, transitDetails: { stopDetails: { departureTime: iso(depart), arrivalTime: iso(arrive) } } },
          { travelMode: "WALK", staticDuration: `${walkAfter}s` },
        ],
      },
    ],
  };
}

const roadRoute = (seconds: number): GoogleRoute => ({ duration: `${seconds}s`, legs: [{ steps: [{ travelMode: "DRIVE" }] }] });
const ok = (route: GoogleRoute): Attempt => ({ kind: "route", route, seconds: durationSeconds(route.duration)!, fallback: false });

describe("departure request", () => {
  const body = {
    mode: "transit",
    origin: { lat: 25.0478, lng: 121.517 },
    destination: { address: "  台北   101 " },
    arriveBy: iso(START + 60 * MIN),
    utcOffsetMinutes: 480,
    language: "zh-TW",
    region: "tw",
  };

  it("accepts the app's request and folds the destination's whitespace", () => {
    const parsed = parseDepartureRequest(body, START);
    assert.deepEqual(parsed, {
      mode: "transit",
      origin: { point: { lat: 25.0478, lng: 121.517 } },
      destination: "台北 101",
      arriveBy: START + 60 * MIN,
      plan: null,
      utcOffsetMinutes: 480,
      language: "zh-TW",
      region: "tw",
      debugBuild: false,
    });
    assert.deepEqual(parseDepartureRequest({ ...body, origin: { address: "台北車站" }, arriveBy: null, debugBuild: true }, START)?.origin, { address: "台北車站" });
  });

  it("refuses unknown fields, unknown modes and malformed places", () => {
    const bad: Record<string, unknown>[] = [
      { ...body, extra: 1 },
      { ...body, mode: "bicycle" },
      { ...body, origin: { lat: 91, lng: 0 } },
      { ...body, origin: { lat: 25, lng: Number.NaN } },
      { ...body, origin: { lat: 25, lng: 121, address: "x" } },
      { ...body, origin: { address: " " } },
      { ...body, destination: { lat: 25, lng: 121 } },
      { ...body, destination: { address: "a".repeat(201) } },
      { ...body, destination: { address: "line\u0000break" } },
      { ...body, destination: "台北101" },
    ];
    for (const value of bad) assert.equal(parseDepartureRequest(value, START), null, JSON.stringify(value));
    assert.ok(parseDepartureRequest({ ...body, destination: { address: "字".repeat(200) } }, START));
  });

  it("refuses an arrival in the past or more than 100 days ahead, and a malformed offset, plan, language or region", () => {
    const bad: Record<string, unknown>[] = [
      { ...body, arriveBy: iso(START - 2 * MIN) },
      { ...body, arriveBy: iso(START + 101 * 86_400_000) },
      { ...body, arriveBy: "tomorrow" },
      { ...body, utcOffsetMinutes: 900 },
      { ...body, utcOffsetMinutes: 480.5 },
      { ...body, utcOffsetMinutes: undefined },
      { ...body, plan: "short" },
      { ...body, language: "zh_TW" },
      { ...body, region: "TW" },
      { ...body, debugBuild: "yes" },
    ];
    for (const value of bad) assert.equal(parseDepartureRequest(value, START), null, JSON.stringify(value));
    assert.ok(parseDepartureRequest({ ...body, plan: "A".repeat(43) }, START));
  });
});

describe("departure configuration and region", () => {
  it("blocks the United Kingdom by default; DEPARTURE_BLOCKED_COUNTRIES replaces the list", () => {
    assert.deepEqual([...blockedCountries({} as Env)], ["GB"]);
    assert.deepEqual([...blockedCountries({ DEPARTURE_BLOCKED_COUNTRIES: " " } as Env)], ["GB"]);
    assert.deepEqual([...blockedCountries({ DEPARTURE_BLOCKED_COUNTRIES: "gb, ie,CH" } as Env)], ["GB", "IE", "CH"]);
  });

  it("lets a Debug build test in a blocked country only from a typed starting point", () => {
    const blocked = new Set(["GB"]);
    assert.equal(regionAllows("TW", blocked, trip()), true);
    assert.equal(regionAllows(null, blocked, trip()), true, "not served by Cloudflare (tests)");
    assert.equal(regionAllows(UNKNOWN_COUNTRY, blocked, trip()), false, "Cloudflare could not tell the country");
    assert.equal(regionAllows(UNKNOWN_COUNTRY, blocked, trip({ debugBuild: true })), true);
    assert.equal(regionAllows("GB", blocked, trip()), false);
    assert.equal(regionAllows("GB", blocked, trip({ debugBuild: true })), true);
    assert.equal(regionAllows("GB", blocked, trip({ debugBuild: true, origin: { point: { lat: 51.5, lng: -0.1 } } })), false);
  });

  it("reads Cloudflare's country: XX, T1 and a missing country are unknown; no cf at all is not Cloudflare", () => {
    const at = (cf: unknown) => {
      const request = new Request("https://worker.test/");
      if (cf !== undefined) Object.defineProperty(request, "cf", { value: cf });
      return requestCountry(request);
    };
    assert.equal(at({ country: "TW" }), "TW");
    assert.equal(at({ country: "GB" }), "GB");
    for (const cf of [{ country: "XX" }, { country: "T1" }, {}, { country: null }]) assert.equal(at(cf), UNKNOWN_COUNTRY, JSON.stringify(cf));
    assert.equal(at(undefined), null);
  });

  it("reads the limits, with 0 turning a tier off", () => {
    assert.equal(weeklyPlans({} as Env), 2);
    assert.equal(weeklyPlans({ DEPARTURE_WEEKLY_PLANS: "x" } as Env), 2);
    assert.equal(userDailyCalls({} as Env), 30);
    assert.equal(dailyCap({} as Env, "enterprise"), 25);
    assert.equal(dailyCap({ DEPARTURE_DAILY_PRO: "0" } as Env, "pro"), 0);
    assert.equal(dailyCap({ DEPARTURE_DAILY_ESSENTIALS: "-1" } as Env, "essentials"), 250);
  });

  it("lets one user use at most a third of a tier's day, and always one whole request", () => {
    const production = { DEPARTURE_USER_DAILY_CALLS: "30", DEPARTURE_DAILY_ESSENTIALS: "240", DEPARTURE_DAILY_PRO: "119", DEPARTURE_DAILY_ENTERPRISE: "22" } as Env;
    assert.deepEqual([userTierCalls(production, "essentials"), userTierCalls(production, "pro"), userTierCalls(production, "enterprise")], [30, 30, 7]);
    const dev = { DEPARTURE_USER_DAILY_CALLS: "30", DEPARTURE_DAILY_ESSENTIALS: "10", DEPARTURE_DAILY_PRO: "6", DEPARTURE_DAILY_ENTERPRISE: "3" } as Env;
    assert.deepEqual([userTierCalls(dev, "essentials"), userTierCalls(dev, "pro"), userTierCalls(dev, "enterprise")], [3, 3, 3]);
  });

  it("counts Google's daily quota to midnight US Pacific time", () => {
    assert.equal(untilPacificMidnight(START), 23 * 3600, "08:00 UTC is 01:00 PDT");
    assert.equal(untilPacificMidnight(Date.UTC(2026, 11, 15, 7, 59, 0)), 60, "23:59 PST");
  });

  it("keeps every tier's daily cap within 80 % of its monthly free calls over the 32 UTC days a Google month touches", () => {
    for (const sku of ["essentials", "pro", "enterprise"] as const) {
      assert.ok(DEFAULT_DAILY_CAPS[sku] * DAYS_PER_GOOGLE_MONTH <= FREE_MONTHLY_CALLS[sku] * 0.8, sku);
    }
    assert.deepEqual(FREE_MONTHLY_CALLS, { essentials: 10_000, pro: 5_000, enterprise: 1_000 });
    assert.deepEqual(MODE_SKU, { transit: "essentials", walk: "essentials", drive: "pro", two_wheeler: "enterprise" });
  });
});

describe("departure weeks and plans", () => {
  it("starts the week on the user's Monday", () => {
    // 2026-10-19 is a Monday. 2026-10-18T16:30Z is Monday 00:30 in Taipei (UTC+8) but Sunday in London (UTC+1).
    const t = Date.UTC(2026, 9, 18, 16, 30);
    assert.equal(weekOf(t, 480), "20261019");
    assert.equal(weekOf(t, 60), "20261012");
    assert.equal(weekOf(Date.UTC(2026, 9, 25, 23, 59), 0), "20261019");
    assert.equal(weekOf(Date.UTC(2026, 9, 26, 0, 0), 0), "20261026");
    assert.equal(weekOf(Date.UTC(1970, 0, 5), 0), "19700105");
  });

  it("says how long until the next Monday 00:00 local", () => {
    assert.equal(untilNextWeek(Date.UTC(2026, 9, 25, 23, 0), 0), 3600);
    assert.equal(untilNextWeek(Date.UTC(2026, 9, 18, 15, 30), 480), 1800); // Sunday 23:30 in Taipei
    assert.equal(untilNextWeek(Date.UTC(2026, 9, 18, 16, 0), 480), 7 * 86_400); // Monday 00:00 in Taipei: a new week
    assert.equal(untilNextWeek(Date.UTC(2026, 9, 26, 0, 0), 0), 7 * 86_400);
  });

  it("binds a plan to its token, destination and arrival without storing either", async () => {
    const token = "A".repeat(43);
    const a = await planBinding(token, "台北 101", 1000);
    assert.equal(a, await planBinding(token, "  台北   101 ", 1000));
    assert.notEqual(a, await planBinding(token, "台北車站", 1000));
    assert.notEqual(a, await planBinding(token, "台北 101", 2000));
    assert.notEqual(a, await planBinding("B".repeat(43), "台北 101", 1000));
    assert.doesNotMatch(a, /台北/);
  });

  it("keeps a plan until two hours after the arrival", () => {
    assert.equal(planExpiry(START + 3600_000, START), START + 3 * 3600_000);
    assert.equal(planExpiry(null, START), START + 2 * 3600_000);
  });
});

describe("Google request and answer", () => {
  it("asks transit by arrival time and driving pessimistically, with one route and no extras", () => {
    const transit = googleRequestBody(trip(), { arrive: START + 60 * MIN });
    assert.deepEqual(transit, {
      origin: { address: "台北車站" },
      destination: { address: "台北101" },
      computeAlternativeRoutes: false,
      travelMode: "TRANSIT",
      arrivalTime: iso(START + 60 * MIN),
      languageCode: "zh-TW",
      regionCode: "tw",
    });
    const drive = googleRequestBody(trip({ mode: "drive", origin: { point: { lat: 25, lng: 121.5 } }, language: null, region: null }), { leave: START + 5 * MIN });
    assert.deepEqual(drive, {
      origin: { location: { latLng: { latitude: 25, longitude: 121.5 } } },
      destination: { address: "台北101" },
      computeAlternativeRoutes: false,
      travelMode: "DRIVE",
      routingPreference: "TRAFFIC_AWARE_OPTIMAL",
      trafficModel: "PESSIMISTIC",
      departureTime: iso(START + 5 * MIN),
    });
    const scooter = googleRequestBody(trip({ mode: "two_wheeler" }), { leave: "now" });
    assert.equal(scooter.travelMode, "TWO_WHEELER");
    assert.equal(scooter.trafficModel, undefined, "trafficModel is DRIVE only");
    assert.equal(scooter.departureTime, undefined, "now: no departureTime");
    assert.equal(googleRequestBody(trip({ mode: "walk" }), { leave: "now" }).routingPreference, undefined);
  });

  it("asks only for fields shown to the user, never billing extras", () => {
    assert.doesNotMatch(FIELD_MASK, /toll|fuel|speedReading|polyline|\*/i);
    assert.match(FIELD_MASK, /routes\.legs\.steps\.transitDetails/);
    assert.match(FIELD_MASK, /(^|,)fallbackInfo(,|$)/);
  });

  it("reads routes, missing places, quota and outages", () => {
    const route = roadRoute(600);
    assert.deepEqual(readGoogleAnswer(200, { routes: [route] }), { kind: "route", route, seconds: 600, fallback: false });
    assert.deepEqual(readGoogleAnswer(200, { routes: [route], fallbackInfo: { routingMode: "FALLBACK_TRAFFIC_UNAWARE", reason: "LATENCY_EXCEEDED" } }), {
      kind: "route",
      route,
      seconds: 750,
      fallback: true,
    });
    assert.deepEqual(readGoogleAnswer(200, {}), { kind: "no_route" });
    assert.deepEqual(readGoogleAnswer(200, { geocodingResults: { destination: { geocoderStatus: { code: 5 } } } }), { kind: "not_found", place: "destination" });
    assert.deepEqual(readGoogleAnswer(200, { geocodingResults: { origin: { geocoderStatus: { code: 5 } }, destination: {} } }), { kind: "not_found", place: "origin" });
    assert.deepEqual(readGoogleAnswer(400, { error: {} }), { kind: "no_route" });
    const badKey = { error: { code: 400, status: "INVALID_ARGUMENT", details: [{ "@type": "type.googleapis.com/google.rpc.ErrorInfo", reason: "API_KEY_INVALID" }] } };
    assert.equal(keyRefused(badKey), true);
    assert.deepEqual(readGoogleAnswer(400, badKey), { kind: "unavailable", status: 400 });
    assert.deepEqual(readGoogleAnswer(429, {}), { kind: "quota" });
    assert.deepEqual(readGoogleAnswer(403, {}), { kind: "unavailable", status: 403 });
    assert.deepEqual(readGoogleAnswer(503, {}), { kind: "unavailable", status: 503 });
    assert.equal(durationSeconds("12.5s"), 12);
    assert.equal(durationSeconds("12m"), null);
    const billed = (status: number | null, body: unknown = {}) => billable(status, status === null ? null : readGoogleAnswer(status, body));
    assert.deepEqual([200, 400, 404, 429, 401, 403, 500].map((s) => billed(s)), [true, true, true, false, false, false, false]);
    assert.equal(billed(400, badKey), false, "Google does not bill a refused key");
    assert.equal(billed(null), true, "an unknown outcome counts as billed");
  });
});

describe("when to leave", () => {
  const A = START + 60 * MIN;

  it("transit: leave the walk before the first vehicle, arrive the walk after the last", () => {
    const route = transitRoute(START + 30 * MIN, START + 46 * MIN);
    assert.deepEqual(transitTimes(route), { departAt: START + 26 * MIN, arriveAt: START + 51 * MIN });
    assert.equal(transitTimes(roadRoute(600)), null);
  });

  it("transit: one call by the arrival time", async () => {
    const timings: Timing[] = [];
    const solved = await solveTransit(A, START, async (timing) => {
      timings.push(timing);
      return ok(transitRoute(START + 30 * MIN + 20_000, START + 46 * MIN));
    });
    assert.deepEqual(timings, [{ arrive: A }]);
    assert.ok(solved.kind === "ok" && solved.departAt === START + 26 * MIN && !solved.late && !solved.estimate, "floored to the minute");
  });

  it("transit: too late for the arrival time → plan from now and say it is late", async () => {
    const timings: Timing[] = [];
    const solved = await solveTransit(START + 10 * MIN, START, async (timing) => {
      timings.push(timing);
      return "arrive" in timing ? ok(transitRoute(START - 20 * MIN, START + 5 * MIN)) : ok(transitRoute(START + 3 * MIN, START + 20 * MIN));
    });
    assert.deepEqual(timings, [{ arrive: START + 10 * MIN }, { leave: "now" }]);
    assert.ok(solved.kind === "ok" && solved.late && solved.arriveAt === START + 25 * MIN);
  });

  it("transit: seconds behind Google's itinerary already plans from now (the first vehicle may be missed)", async () => {
    const now = START + 50_000;
    const timings: Timing[] = [];
    const solved = await solveTransit(START + 30 * MIN, now, async (timing) => {
      timings.push(timing);
      return "arrive" in timing ? ok(transitRoute(START + 4 * MIN, START + 25 * MIN)) : ok(transitRoute(START + 10 * MIN, START + 31 * MIN));
    });
    assert.deepEqual(timings, [{ arrive: START + 30 * MIN }, { leave: "now" }]);
    assert.ok(solved.kind === "ok" && solved.late && solved.departAt === START + 6 * MIN);
  });

  it("transit: a walk-only answer leaves the route's duration before the arrival", async () => {
    const solved = await solveTransit(A, START, async () => ok(roadRoute(900)));
    assert.ok(solved.kind === "ok" && solved.departAt === A - 15 * MIN && solved.arriveAt === A);
  });

  /** Google as a function of the departure: minutes of driving when leaving at t. */
  function road(minutesAt: (t: number) => number, asked: number[] = []) {
    return async (timing: Timing): Promise<Attempt> => {
      const t = "leave" in timing && timing.leave !== "now" ? timing.leave : START;
      asked.push(t);
      return ok(roadRoute(Math.round(minutesAt(t) * 60)));
    };
  }

  it("driving: confirmed on the first guess when traffic doesn't change", async () => {
    const asked: number[] = [];
    const solved = await solveRoad(A, START, road(() => 30, asked), MAX_CALLS.drive);
    assert.deepEqual(asked, [START + 30 * MIN]);
    assert.ok(solved.kind === "ok" && solved.departAt === START + 30 * MIN && solved.arriveAt === A && !solved.late && !solved.estimate);
  });

  // Evening peak: leaving at 18:30 takes 40 min, every minute earlier adds s minutes. Arrive by 19:00.
  for (const s of [0.5, 0.67, 0.8]) {
    it(`driving: heavier traffic the earlier you leave (${s} min per minute) still arrives on time`, async () => {
      const now = Date.UTC(2026, 9, 15, 9, 0);
      const at1830 = Date.UTC(2026, 9, 15, 18, 30);
      const by = Date.UTC(2026, 9, 15, 19, 0);
      const minutes = (t: number) => 40 + Math.max(0, (at1830 - t) / MIN) * s;
      const solved = await solveRoad(by, now, road(minutes), 3);
      assert.ok(solved.kind === "ok" && !solved.late && !solved.estimate, JSON.stringify(solved));
      if (solved.kind !== "ok") return;
      assert.ok(solved.departAt + minutes(solved.departAt) * MIN <= by, "Google's own duration from that departure arrives in time");
      assert.ok(solved.arriveAt <= by && solved.arriveAt === solved.departAt + Math.round(minutes(solved.departAt) * 60) * 1000);
      assert.ok(by - (solved.departAt + minutes(solved.departAt) * MIN) <= 6 * MIN, "not much too early");
    });
  }

  it("driving: keeps the latest departure Google confirmed, with that departure's own arrival and route", async () => {
    // 35 min before 16:30, 75 min after: leaving 16:15 arrives 16:50.
    const now = Date.UTC(2026, 9, 15, 16, 0);
    const by = Date.UTC(2026, 9, 15, 17, 30);
    const solved = await solveRoad(by, now, road((t) => (t < Date.UTC(2026, 9, 15, 16, 30) ? 35 : 75)), 3);
    assert.ok(solved.kind === "ok" && !solved.late);
    if (solved.kind !== "ok") return;
    assert.ok(solved.departAt + (solved.departAt < Date.UTC(2026, 9, 15, 16, 30) ? 35 : 75) * MIN === solved.arriveAt, "arrival of that departure");
    assert.ok(solved.arriveAt <= by);
  });

  it("driving: late only when even leaving now is too late, with now's own duration", async () => {
    const asked: number[] = [];
    const solved = await solveRoad(START + 20 * MIN, START, road(() => 30, asked), 3);
    assert.deepEqual(asked, [START], "the first guess is already now");
    assert.ok(solved.kind === "ok" && solved.late && solved.departAt === START && solved.arriveAt === START + 30 * MIN);

    // Rush hour starting: 40 min now, much longer later. Leaving now is in time.
    const now = Date.UTC(2026, 9, 15, 16, 0);
    const by = Date.UTC(2026, 9, 15, 17, 30);
    const onset = await solveRoad(by, now, road((t) => 40 + Math.max(0, (t - now) / MIN) * 1.2), 3);
    assert.ok(onset.kind === "ok" && !onset.late && onset.arriveAt <= by, JSON.stringify(onset));
  });

  it("driving: Google failing before any answer in time is a failure, not a guess", async () => {
    // 40 min drive, arrive by 35 minutes from now: the first guess is late, then Google fails.
    let n = 0;
    const solved = await solveRoad(START + 35 * MIN, START, async () => (++n === 1 ? ok(roadRoute(2400)) : { kind: "unavailable", status: 503 }), 3);
    assert.deepEqual(solved, { kind: "unavailable", status: 503 });
  });

  it("driving: when leaving earlier doesn't help (a closure lifting later), it says late, never a made-up arrival", async () => {
    // Closed until 09:20, then 30 min: leaving at t takes (09:20 − t) + 30 min. Arrive by 09:45: impossible.
    const now = Date.UTC(2026, 9, 15, 9, 0);
    const open = Date.UTC(2026, 9, 15, 9, 20);
    const by = Date.UTC(2026, 9, 15, 9, 45);
    const solved = await solveRoad(by, now, road((t) => Math.max(0, (open - t) / MIN) + 30), 3);
    assert.ok(solved.kind === "ok" && solved.late && solved.estimate && solved.departAt === now && solved.arriveAt > by, JSON.stringify(solved));
  });

  it("driving: never more calls than allowed", async () => {
    let calls = 0;
    const flapping = await solveRoad(START + 3 * 60 * MIN, START, async () => {
      calls++;
      return ok(roadRoute(calls % 2 ? 3600 : 7200));
    }, 3);
    assert.ok(calls <= 3);
    assert.equal(flapping.kind, "ok");
  });

  it("driving: a fallback without live traffic is marked as an estimate", async () => {
    const solved = await solveRoad(A, START, async () => ({ kind: "route", route: roadRoute(1500), seconds: 1875, fallback: true }), 3);
    assert.ok(solved.kind === "ok" && solved.estimate && solved.arriveAt <= A);
  });

  it("how long: leave now, one call", async () => {
    const timings: Timing[] = [];
    const solved = await solveRoad(null, START + 30_000, async (timing) => {
      timings.push(timing);
      return ok(roadRoute(600));
    }, 3);
    assert.deepEqual(timings, [{ leave: "now" }]);
    assert.ok(solved.kind === "ok" && solved.departAt === START && solved.arriveAt === START + 30_000 + 10 * MIN);
  });

  it("walking: one call, the walk before the arrival", async () => {
    const solved = await solveWalk(A, START, async () => ok(roadRoute(1250)));
    assert.ok(solved.kind === "ok" && solved.departAt === START + 39 * MIN && !solved.late);
  });

  it("passes a missing place or no route straight through", async () => {
    const missing = await solveRoad(A, START, async () => ({ kind: "not_found", place: "destination" }), 3);
    assert.deepEqual(missing, { kind: "not_found", place: "destination" });
  });
});

describe("departure ledger", () => {
  const base: ReserveInput = {
    id: "key-a",
    sku: "pro",
    day: "20261015",
    week: "20261012",
    calls: 3,
    tierCap: 6,
    userDailyCalls: 30,
    weeklyPlans: 2,
    recheck: null,
    now: START,
  };

  it("reserves the calls and the week's plan together, and refuses past any limit", () => {
    const kv = new MemorySyncKv();
    assert.deepEqual(reserve(kv, base), { ok: true, plansUsed: 1 });
    assert.equal(kv.get("sku:pro:20261015"), 3);
    assert.equal(kv.get("user:key-a:pro:20261015"), 3);
    assert.deepEqual(reserve(kv, { ...base, id: "key-b" }), { ok: true, plansUsed: 1 });
    assert.deepEqual(reserve(kv, { ...base, id: "key-c" }), { ok: false, reason: "capacity_reached", plansUsed: 0 });
    assert.equal(kv.get("sku:pro:20261015"), 6, "a refusal reserves nothing");
    assert.deepEqual(reserve(kv, { ...base, sku: "essentials", calls: 2, tierCap: 250 }), { ok: true, plansUsed: 2 });
    assert.deepEqual(reserve(kv, { ...base, sku: "essentials", calls: 2, tierCap: 250 }), { ok: false, reason: "weekly_limit", plansUsed: 2 });
    assert.deepEqual(reserve(kv, { ...base, id: "key-d", sku: "essentials", calls: 2, tierCap: 250, userDailyCalls: 1 }), {
      ok: false,
      reason: "user_daily_limit",
      plansUsed: 0,
    });
  });

  it("gives back only what was not billed, and the week's plan when there was no route", () => {
    const kv = new MemorySyncKv();
    reserve(kv, base);
    assert.deepEqual(settle(kv, { id: "key-a", sku: "pro", day: "20261015", week: "20261012", unbilled: 1, releasePlan: true, releaseRecheck: null, createPlan: null }), {
      plansUsed: 0,
    });
    assert.equal(kv.get("sku:pro:20261015"), 2);
    assert.equal(kv.get("user:key-a:pro:20261015"), 2);
    assert.equal(kv.get("week:key-a:20261012"), undefined);
  });

  it("checks a recheck against its plan: owner, binding, expiry and the number of rechecks", () => {
    const kv = new MemorySyncKv();
    settle(kv, {
      id: "key-a",
      sku: "pro",
      day: "20261015",
      week: "20261012",
      unbilled: 0,
      releasePlan: false,
      releaseRecheck: null,
      createPlan: { hash: "h1", entry: { id: "key-a", binding: "b1", rechecks: 0, expiresAt: START + 3600_000 } },
    });
    const recheck = (fields: Partial<ReserveInput> = {}, plan = { hash: "h1", binding: "b1", maxRechecks: 1 }) =>
      reserve(kv, { ...base, weeklyPlans: 0, recheck: plan, ...fields });
    assert.equal(recheck({ id: "key-b" }).ok, false);
    assert.deepEqual(recheck({}, { hash: "h1", binding: "other", maxRechecks: 1 }), { ok: false, reason: "invalid_plan", plansUsed: 0 });
    assert.deepEqual(recheck({ now: START + 3600_000 }), { ok: false, reason: "invalid_plan", plansUsed: 0 });
    assert.deepEqual(recheck(), { ok: true, plansUsed: 0 }, "a recheck needs no weekly plan left");
    assert.deepEqual(recheck(), { ok: false, reason: "recheck_limit", plansUsed: 0 });
    settle(kv, { id: "key-a", sku: "pro", day: "20261015", week: "20261012", unbilled: 3, releasePlan: false, releaseRecheck: "h1", createPlan: null });
    assert.deepEqual(recheck(), { ok: true, plansUsed: 0 }, "a recheck Google couldn't answer is given back");
  });

  it("forgets past days, past weeks and expired plans", () => {
    const kv = new MemorySyncKv();
    const now = Date.UTC(2026, 9, 20, 12, 0);
    for (const key of ["sku:pro:20261018", "sku:pro:20261019", "user:k:pro:20261018", "week:k:20261005", "week:k:20261012"]) kv.put(key, 1);
    kv.put("plan:old", { id: "k", binding: "b", rechecks: 0, expiresAt: now - 1 });
    kv.put("plan:new", { id: "k", binding: "b", rechecks: 0, expiresAt: now + 1 });
    assert.equal(sweep(kv, now), 4);
    assert.deepEqual([...kv.store.keys()].sort(), ["plan:new", "sku:pro:20261019", "week:k:20261012"]);
  });
});

// ---------------------------------------------------------------------------------------------------------------------
// The route, end to end (dev token identity)

const DEV = "dev-secret-token";

function departureHarness(env: Partial<Env> = {}): Harness {
  return makeHarness({ env: { ALLOW_DEV_TOKEN: "true", GOOGLE_ROUTES_API_KEY: "test-routes-key", ...env } });
}

function post(h: Harness, fields: Record<string, unknown>, country: string | null = "TW", extra: Record<string, string> = {}) {
  return h.request("/v1/departure/routes", {
    method: "POST",
    headers: { "x-dev-token": DEV, "content-type": "application/json", ...extra },
    body: JSON.stringify(fields),
    cf: country === null ? {} : { country },
  } as RequestInit);
}

const request = {
  mode: "transit",
  origin: { lat: 25.0478, lng: 121.517 },
  destination: { address: "台北101" },
  arriveBy: iso(START + 60 * MIN),
  utcOffsetMinutes: 480,
  language: "zh-TW",
  region: "tw",
};

function googleCalls(h: Harness): FetchCall[] {
  return h.calls.filter((c) => c.url === ROUTES_URL);
}

function bodyOf(call: FetchCall): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(call.body!)) as Record<string, unknown>;
}

describe("POST /v1/departure/routes", () => {
  let logged: string[] = [];
  const original = { log: console.log, warn: console.warn, error: console.error };
  beforeEach(() => {
    logged = [];
    console.log = console.warn = console.error = (line: unknown) => logged.push(String(line));
  });
  afterEach(() => {
    Object.assign(console, original);
  });

  function transitAnswer(h: Harness) {
    h.setResponder(() => Response.json({ routes: [transitRoute(START + 30 * MIN, START + 46 * MIN)] }));
  }

  it("plans a trip: Google with the server's key and fixed field mask, then the time to leave and a plan", async () => {
    const h = departureHarness();
    transitAnswer(h);
    const response = await post(h, request);
    assert.equal(response.status, 200);
    const body = await jsonOf(response);
    assert.equal(body.result, "ok");
    assert.equal(body.departAt, iso(START + 26 * MIN));
    assert.equal(body.arriveAt, iso(START + 51 * MIN));
    assert.equal(body.late, false);
    assert.equal(body.estimate, false);
    assert.equal(body.plansLeft, 1);
    assert.match(String(body.plan), /^[A-Za-z0-9_-]{43}$/);
    assert.ok((body.route as Record<string, unknown>).legs);

    const [call, ...more] = googleCalls(h);
    assert.equal(more.length, 0);
    assert.equal(call!.method, "POST");
    assert.equal(call!.headers.get("x-goog-api-key"), "test-routes-key");
    assert.equal(call!.headers.get("x-goog-fieldmask"), FIELD_MASK);
    assert.equal(call!.headers.get("x-dev-token"), null, "no client header reaches Google");
    assert.equal(bodyOf(call!).arrivalTime, iso(START + 60 * MIN));

    // START is Thursday 2026-10-15; the week starts Monday 2026-10-12. Transit reserved 2, used 1.
    assert.equal(h.ledger.kv.get("week:dev:20261012"), 1);
    assert.equal(h.ledger.kv.get("sku:essentials:20261015"), 1);
    assert.equal(h.ledger.kv.get("user:dev:essentials:20261015"), 1);
    assert.equal(h.background.length, 1, "solving and settling run under ctx.waitUntil");
    assert.equal([...h.ledger.kv.store.keys()].filter((k) => k.startsWith("plan:")).length, 1);
    assert.equal(h.kv.keysWithPrefix("dep:").length, 0, "nothing in KV");
    assert.ok(h.ledger.alarm !== null, "daily clean-up scheduled");

    const text = logged.join("\n");
    assert.match(text, /"event":"departure_route"/);
    assert.doesNotMatch(text, /台北|25\.04|121\.5|test-routes-key|"dev"/, "no place, coordinates, key or identity in the logs");
    const stored = JSON.stringify([...h.ledger.kv.store.entries()]) + JSON.stringify(h.ledger.requests);
    assert.doesNotMatch(stored, /台北|25\.04|121\.5/, "no place or coordinates in the ledger");
  });

  it("reserves before calling Google: the count already holds this request while Google answers", async () => {
    const h = departureHarness();
    let during: unknown;
    h.setResponder(() => {
      during = h.ledger.kv.get("sku:pro:20261015");
      return Response.json({ routes: [roadRoute(1800)] });
    });
    assert.equal((await post(h, { ...request, mode: "drive" })).status, 200);
    assert.equal(during, 3, "the whole worst case was reserved first");
    assert.equal(h.ledger.kv.get("sku:pro:20261015"), 1, "then settled to the calls made");
  });

  it("never lets requests running at the same time past the week's plans or a daily cap", async () => {
    const slowGoogle = async () => {
      await new Promise((resolve) => setTimeout(resolve, 20));
      return Response.json({ routes: [roadRoute(1800)] });
    };
    const burst = async (h: Harness) => (await Promise.all(Array.from({ length: 10 }, () => post(h, { ...request, mode: "drive" })))).map((r) => r.status);

    const week = departureHarness({ DEPARTURE_DAILY_PRO: "30", DEPARTURE_WEEKLY_PLANS: "2" });
    week.setResponder(slowGoogle);
    assert.equal((await burst(week)).filter((s) => s === 200).length, 2);
    assert.equal(week.ledger.kv.get("week:dev:20261012"), 2);

    // Pro cap 30 → one user's share is 10 calls: three drive requests (3 reserved each), however many at once.
    const daily = departureHarness({ DEPARTURE_DAILY_PRO: "30", DEPARTURE_WEEKLY_PLANS: "10" });
    daily.setResponder(slowGoogle);
    const statuses = await burst(daily);
    assert.equal(statuses.filter((s) => s === 200).length, 3);
    assert.equal(statuses.filter((s) => s === 429).length, 7);
    assert.ok(googleCalls(daily).length <= 9);
  });

  it("allows two new plans a week; the third waits for Monday", async () => {
    const h = departureHarness();
    transitAnswer(h);
    assert.equal((await post(h, request)).status, 200);
    assert.equal((await jsonOf(await post(h, request))).plansLeft, 0);
    const refused = await post(h, request);
    assert.equal(refused.status, 429);
    assert.deepEqual(await refused.json(), { error: "weekly_limit" });
    // Thursday 16:00 Taipei → Monday 00:00 Taipei: 3 days 8 hours.
    assert.equal(refused.headers.get("retry-after"), String(3 * 86_400 + 8 * 3600));
    assert.equal(googleCalls(h).length, 2);

    h.clock.now += 4 * 86_400_000; // next week
    h.setResponder(() => Response.json({ routes: [transitRoute(h.clock.now + 30 * MIN, h.clock.now + 46 * MIN)] }));
    assert.equal((await post(h, { ...request, arriveBy: iso(h.clock.now + 60 * MIN) })).status, 200);
  });

  it("rechecks a plan for free: a new start or way to travel is the same trip, another place is not", async () => {
    const h = departureHarness({ DEPARTURE_PLAN_RECHECKS: "2" });
    transitAnswer(h);
    const { plan } = (await jsonOf(await post(h, request))) as { plan: string };
    const recheck = await jsonOf(await post(h, { ...request, plan, origin: { address: "台北車站" } }));
    assert.equal(recheck.result, "ok");
    assert.equal(recheck.plan, plan);
    assert.equal(recheck.plansLeft, 1, "not counted");
    h.setResponder(() => Response.json({ routes: [roadRoute(1800)] }));
    assert.equal((await post(h, { ...request, plan, mode: "drive" })).status, 200);
    assert.equal(h.ledger.kv.get("week:dev:20261012"), 1);

    const limited = await post(h, { ...request, plan });
    assert.equal(limited.status, 429);
    assert.deepEqual(await limited.json(), { error: "recheck_limit" });

    for (const other of [{ ...request, plan, destination: { address: "台北車站" } }, { ...request, plan, arriveBy: iso(START + 90 * MIN) }, { ...request, plan: "A".repeat(43) }]) {
      const refused = await post(h, other);
      assert.equal(refused.status, 403);
      assert.deepEqual(await refused.json(), { error: "invalid_plan" });
    }
  });

  it("refuses another user's plan", async () => {
    const h = departureHarness();
    transitAnswer(h);
    const { plan } = (await jsonOf(await post(h, request))) as { plan: string };
    const [key, entry] = [...h.ledger.kv.store.entries()].find(([k]) => k.startsWith("plan:"))!;
    h.ledger.kv.put(key, { ...(entry as Record<string, unknown>), id: "someone-else" });
    assert.equal((await post(h, { ...request, plan })).status, 403);
  });

  it("is off in the United Kingdom and where the country is unknown, except a Debug build planning from a typed start", async () => {
    const h = departureHarness();
    transitAnswer(h);
    for (const country of ["GB", "XX", "T1", null]) {
      const refused = await post(h, request, country);
      assert.equal(refused.status, 403, String(country));
      assert.deepEqual(await refused.json(), { error: "region_unavailable" });
    }
    assert.equal((await post(h, { ...request, debugBuild: true }, "GB")).status, 403, "never a UK location to Google");
    assert.equal((await post(h, { ...request, debugBuild: true, origin: { address: "台北車站" } }, "GB")).status, 200);
    assert.equal((await post(h, { ...request, origin: { address: "台北車站" } }, "GB")).status, 403, "Release builds never");
    assert.equal(googleCalls(h).length, 1);
  });

  it("stops at the tier's daily cap, and a cap below the worst case turns the tier off", async () => {
    const h = departureHarness({ DEPARTURE_DAILY_PRO: "2" });
    const refused = await post(h, { ...request, mode: "drive" });
    assert.equal(refused.status, 429);
    assert.deepEqual(await refused.json(), { error: "capacity_reached" });
    assert.equal(refused.headers.get("retry-after"), String(16 * 3600), "until 00:00 UTC");
    assert.equal(googleCalls(h).length, 0);
    assert.equal(h.ledger.kv.get("week:dev:20261012"), undefined, "not counted");

    const off = departureHarness({ DEPARTURE_DAILY_ENTERPRISE: "0" });
    assert.equal((await post(off, { ...request, mode: "two_wheeler" })).status, 429);
  });

  it("limits one user's Google calls a day whatever the outcome", async () => {
    const h = departureHarness({ DEPARTURE_USER_DAILY_CALLS: "4" });
    h.setResponder(() => Response.json({ geocodingResults: { destination: { geocoderStatus: { code: 5 } } } }));
    assert.equal((await post(h, request)).status, 200); // place_not_found: 1 call
    assert.equal((await post(h, request)).status, 200); // 2
    assert.equal((await post(h, request)).status, 200); // 3 (reserves 2: 2 + 2 ≤ 4)
    const refused = await post(h, request);
    assert.equal(refused.status, 429);
    assert.deepEqual(await refused.json(), { error: "user_daily_limit" });
  });

  it("counts every billed Google call in the tier and solves driving in at most 3", async () => {
    const h = departureHarness();
    let n = 0;
    h.setResponder(() => Response.json({ routes: [roadRoute(++n === 1 ? 3600 : 3000)] })); // 60 min at the first guess, then 50
    const body = await jsonOf(await post(h, { ...request, mode: "drive", arriveBy: iso(START + 3 * 60 * MIN) }));
    assert.equal(body.result, "ok");
    const calls = googleCalls(h);
    assert.ok(calls.length >= 2 && calls.length <= 3);
    assert.equal(h.ledger.kv.get("sku:pro:20261015"), calls.length);
    assert.equal(bodyOf(calls[0]!).departureTime, iso(START + 150 * MIN));
  });

  it("does not count a week's plan when Google finds no place or no route, but does count the calls", async () => {
    const h = departureHarness();
    h.setResponder(() => Response.json({ geocodingResults: { destination: { geocoderStatus: { code: 5, message: "NOT_FOUND" } } } }));
    assert.deepEqual(await jsonOf(await post(h, request)), { result: "place_not_found", place: "destination", plansLeft: 2 });
    h.setResponder(() => Response.json({}));
    assert.deepEqual(await jsonOf(await post(h, request)), { result: "no_route", plansLeft: 2 });
    assert.equal(h.ledger.kv.get("week:dev:20261012"), undefined);
    assert.equal([...h.ledger.kv.store.keys()].filter((k) => k.startsWith("plan:")).length, 0);
    assert.equal(h.ledger.kv.get("sku:essentials:20261015"), 2, "Google still billed the calls");
  });

  it("answers Google's quota with capacity_reached, an outage or a refused key with 502, and gives back unbilled calls", async () => {
    const h = departureHarness();
    h.setResponder(() => new Response("{}", { status: 429 }));
    const quota = await post(h, request);
    assert.equal(quota.status, 429);
    assert.deepEqual(await quota.json(), { error: "capacity_reached" });
    assert.equal(quota.headers.get("retry-after"), String(23 * 3600), "Google's quota starts again at midnight Pacific time");
    h.setResponder(() => new Response("{}", { status: 503 }));
    const outage = await post(h, request);
    assert.equal(outage.status, 502);
    assert.deepEqual(await outage.json(), { error: "upstream_unavailable" });
    h.setResponder(() =>
      Response.json({ error: { code: 400, status: "INVALID_ARGUMENT", details: [{ reason: "API_KEY_INVALID" }] } }, { status: 400 }),
    );
    assert.equal((await post(h, request)).status, 502, "a deleted or wrong key is a server problem, not 'no route'");
    assert.equal(h.ledger.kv.get("week:dev:20261012"), undefined);
    assert.equal(h.ledger.kv.get("sku:essentials:20261015"), undefined, "none of these was billed");

    h.setResponder(() => {
      throw new TypeError("network");
    });
    assert.equal((await post(h, request)).status, 502);
    assert.equal(h.ledger.kv.get("sku:essentials:20261015"), 1, "an unknown outcome stays counted");
  });

  it("marks a driving answer Google made without live traffic as an estimate, with more time", async () => {
    const h = departureHarness();
    h.setResponder(() => Response.json({ routes: [roadRoute(1200)], fallbackInfo: { routingMode: "FALLBACK_TRAFFIC_UNAWARE", reason: "LATENCY_EXCEEDED" } }));
    const body = await jsonOf(await post(h, { ...request, mode: "drive" }));
    assert.equal(body.estimate, true);
    assert.equal(Date.parse(String(body.arriveAt)) - Date.parse(String(body.departAt)), 1500 * 1000, "20 min × 1.25");
  });

  it("fails closed without the ledger, and keeps a reservation the settle step could not reach", async () => {
    const unbound = departureHarness({ SS_DEPARTURE_LEDGER: undefined });
    const misconfigured = await post(unbound, request);
    assert.equal(misconfigured.status, 500);
    assert.equal(googleCalls(unbound).length, 0);

    const h = departureHarness();
    h.ledger.failing = true;
    assert.equal((await post(h, request)).status, 503);
    assert.equal(googleCalls(h).length, 0, "no reservation, no Google call");

    h.ledger.failing = false;
    h.setResponder(() => {
      h.ledger.failing = true; // the settle step after this call can't reach the ledger
      return Response.json({ routes: [transitRoute(START + 30 * MIN, START + 46 * MIN)] });
    });
    const body = await jsonOf(await post(h, request));
    assert.equal(body.result, "ok");
    assert.equal(body.plan, null, "no stored plan, so no token");
    assert.equal(h.ledger.kv.get("sku:essentials:20261015"), 2, "the whole reservation stays counted");
  });

  it("needs the Routes key, a POST, a valid body and the app (no Session token)", async () => {
    const missing = departureHarness({ GOOGLE_ROUTES_API_KEY: undefined });
    const misconfigured = await post(missing, request);
    assert.equal(misconfigured.status, 500);
    assert.deepEqual(await misconfigured.json(), { error: "server_misconfigured" });

    const h = departureHarness();
    assert.equal((await h.request("/v1/departure/routes", { headers: { "x-dev-token": DEV } })).status, 405);
    assert.equal((await post(h, { ...request, mode: "fly" })).status, 400);
    const session = await h.request("/v1/departure/routes", {
      method: "POST",
      headers: { authorization: `Session ${"A".repeat(43)}` },
      body: JSON.stringify(request),
    });
    assert.equal(session.status, 401);
    assert.deepEqual(await session.json(), { error: "attestation_required" });
    const large = await post(h, { ...request, destination: { address: "a".repeat(200) }, language: "x".repeat(5000) });
    assert.equal(large.status, 413);
    assert.equal(googleCalls(h).length, 0);
  });
});
