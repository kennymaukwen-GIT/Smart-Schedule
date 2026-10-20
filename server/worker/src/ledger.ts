// The 「該出發了」 ledger: one Durable Object (SQLite-backed, synchronous storage) that holds every count the free
// limits depend on, so a check and its increment happen together and no two requests can both pass the same check.
//
//   sku:<sku>:<UTC YYYYMMDD>    Google calls reserved or made in that pricing tier that day (everyone together)
//   user:<id>:<sku>:<UTC YYYYMMDD>  Google calls reserved or made for one identity in that tier that day
//   week:<id>:<local Monday>    new plans this week
//   plan:<hex SHA-256(token)>   { id, binding, rechecks, expiresAt } (binding: SHA-256 of token, destination, arrival)
//
// A request reserves its worst case BEFORE it calls Google (reserve) and gives back only the calls it knows were not
// billed afterwards (settle). A request cancelled in between (the client disconnected) keeps its whole reservation:
// counting too much costs a little capacity, counting too little could cost money. Nothing here is a place, a
// coordinate or a route. An alarm deletes the counts of past days and weeks and expired plans once a day.

import type { Sku } from "./departure.ts";

/** The synchronous key-value API of a SQLite-backed Durable Object (ctx.storage.kv). */
export interface SyncKv {
  get<T = unknown>(key: string): T | undefined;
  put<T>(key: string, value: T): void;
  delete(key: string): boolean;
  list<T = unknown>(options?: { prefix?: string }): Iterable<[string, T]>;
}

export interface LedgerState {
  storage: {
    kv: SyncKv;
    getAlarm(): Promise<number | null>;
    setAlarm(scheduledTime: number): Promise<void>;
  };
}

export interface PlanEntry {
  id: string;
  binding: string;
  rechecks: number;
  /** Epoch ms. */
  expiresAt: number;
}

export interface ReserveInput {
  id: string;
  sku: Sku;
  /** UTC YYYYMMDD. */
  day: string;
  /** The user's local Monday, YYYYMMDD. */
  week: string;
  /** Google calls to reserve: the most this request can make. */
  calls: number;
  tierCap: number;
  /** One identity's calls in this tier per day (src/departure.ts userTierCalls). */
  userDailyCalls: number;
  weeklyPlans: number;
  /** A recheck of this plan, or null for a new plan. */
  recheck: { hash: string; binding: string; maxRechecks: number } | null;
  now: number;
}

export type ReserveRefusal = "capacity_reached" | "user_daily_limit" | "weekly_limit" | "invalid_plan" | "recheck_limit";

export type ReserveResult = { ok: true; plansUsed: number } | { ok: false; reason: ReserveRefusal; plansUsed: number };

export interface SettleInput {
  id: string;
  sku: Sku;
  day: string;
  week: string;
  /** Reserved calls Google did not bill: never made, or answered 429 / 401 / 403 / 5xx / an invalid key. */
  unbilled: number;
  /** A new plan that ended without a route: its week slot is given back. */
  releasePlan: boolean;
  /** A recheck Google could not answer: the recheck is given back. */
  releaseRecheck: string | null;
  /** A new plan with a route: remember it for its rechecks. */
  createPlan: { hash: string; entry: PlanEntry } | null;
}

const DAY_MS = 86_400_000;

function count(kv: SyncKv, key: string): number {
  const n = kv.get<number>(key);
  return typeof n === "number" && Number.isInteger(n) && n > 0 ? n : 0;
}

function add(kv: SyncKv, key: string, delta: number): void {
  const next = Math.max(0, count(kv, key) + delta);
  if (next === 0) kv.delete(key);
  else kv.put(key, next);
}

function plan(kv: SyncKv, hash: string): PlanEntry | null {
  const entry = kv.get<PlanEntry>(`plan:${hash}`);
  return entry && typeof entry.id === "string" && typeof entry.binding === "string" && Number.isInteger(entry.rechecks) ? entry : null;
}

/** All checks first, then all increments: synchronous, so nothing else runs in between. */
export function reserve(kv: SyncKv, input: ReserveInput): ReserveResult {
  const tierKey = `sku:${input.sku}:${input.day}`;
  const userKey = `user:${input.id}:${input.sku}:${input.day}`;
  const weekKey = `week:${input.id}:${input.week}`;
  const plansUsed = count(kv, weekKey);
  const refuse = (reason: ReserveRefusal): ReserveResult => ({ ok: false, reason, plansUsed });

  let entry: PlanEntry | null = null;
  if (input.recheck) {
    entry = plan(kv, input.recheck.hash);
    if (!entry || entry.id !== input.id || entry.binding !== input.recheck.binding || entry.expiresAt <= input.now) return refuse("invalid_plan");
    if (entry.rechecks >= input.recheck.maxRechecks) return refuse("recheck_limit");
  } else if (plansUsed >= input.weeklyPlans) {
    return refuse("weekly_limit");
  }
  if (count(kv, tierKey) + input.calls > input.tierCap) return refuse("capacity_reached");
  if (count(kv, userKey) + input.calls > input.userDailyCalls) return refuse("user_daily_limit");

  add(kv, tierKey, input.calls);
  add(kv, userKey, input.calls);
  if (input.recheck && entry) {
    kv.put(`plan:${input.recheck.hash}`, { ...entry, rechecks: entry.rechecks + 1 });
    return { ok: true, plansUsed };
  }
  add(kv, weekKey, 1);
  return { ok: true, plansUsed: plansUsed + 1 };
}

export function settle(kv: SyncKv, input: SettleInput): { plansUsed: number } {
  if (input.unbilled > 0) {
    add(kv, `sku:${input.sku}:${input.day}`, -input.unbilled);
    add(kv, `user:${input.id}:${input.sku}:${input.day}`, -input.unbilled);
  }
  const weekKey = `week:${input.id}:${input.week}`;
  if (input.releasePlan) add(kv, weekKey, -1);
  if (input.releaseRecheck) {
    const entry = plan(kv, input.releaseRecheck);
    if (entry && entry.rechecks > 0) kv.put(`plan:${input.releaseRecheck}`, { ...entry, rechecks: entry.rechecks - 1 });
  }
  if (input.createPlan) kv.put(`plan:${input.createPlan.hash}`, input.createPlan.entry);
  return { plansUsed: count(kv, weekKey) };
}

/** Deletes counts of days before yesterday, weeks before last week, and expired plans. */
export function sweep(kv: SyncKv, now: number): number {
  const yesterday = new Date(now - DAY_MS).toISOString().slice(0, 10).replace(/-/g, "");
  const lastWeek = new Date(now - 8 * DAY_MS).toISOString().slice(0, 10).replace(/-/g, "");
  const stale: string[] = [];
  for (const [key, value] of kv.list<unknown>()) {
    const date = key.slice(key.lastIndexOf(":") + 1);
    if ((key.startsWith("sku:") || key.startsWith("user:")) && date < yesterday) stale.push(key);
    else if (key.startsWith("week:") && date < lastWeek) stale.push(key);
    else if (key.startsWith("plan:")) {
      const expiresAt = (value as Partial<PlanEntry> | undefined)?.expiresAt;
      if (!(typeof expiresAt === "number" && expiresAt > now)) stale.push(key);
    }
  }
  for (const key of stale) kv.delete(key);
  return stale.length;
}

/**
 * The Durable Object. Requests: POST https://ledger/reserve or /settle with a JSON body; answers JSON. Only this
 * Worker can reach it (a Durable Object has no public URL).
 */
export class DepartureLedger {
  private readonly state: LedgerState;

  constructor(state: LedgerState, _env: unknown) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const op = new URL(request.url).pathname;
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    const kv = this.state.storage.kv;
    let result: unknown;
    if (op === "/reserve") result = reserve(kv, body as ReserveInput);
    else if (op === "/settle") result = settle(kv, body as SettleInput);
    else return Response.json({ error: "not_found" }, { status: 404 });
    // Once a day: forget past days, weeks and expired plans.
    if ((await this.state.storage.getAlarm()) === null) await this.state.storage.setAlarm(Date.now() + DAY_MS);
    return Response.json(result);
  }

  async alarm(): Promise<void> {
    sweep(this.state.storage.kv, Date.now());
    await this.state.storage.setAlarm(Date.now() + DAY_MS);
  }
}
