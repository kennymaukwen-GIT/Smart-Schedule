// Bindings, configuration parsing and injectable dependencies.

import type { AttestEnvironment } from "./attestation.ts";

/** The subset of Workers KV this Worker uses (src/index.ts checks that KVNamespace satisfies it). */
export interface KV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number; expiration?: number }): Promise<void>;
  delete(key: string): Promise<void>;
  list(options: { prefix: string; cursor?: string; limit?: number }): Promise<{
    keys: { name: string }[];
    list_complete: boolean;
    cursor?: string;
  }>;
}

/** Cloudflare Workers Rate Limiting binding (`[[ratelimits]]`); src/index.ts checks the real type satisfies it. */
export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Env {
  SS_KV: KV;
  /** Atomic per-location limiter (no KV writes). Optional: without it the KV counters below do the limiting. */
  SS_RATE_LIMITER?: RateLimiter;
  // Secrets (wrangler secret put …): kept across deploys, never in the repository.
  GEMINI_API_KEY?: string;
  SS_DEV_TOKEN?: string;
  APNS_PRIVATE_KEY?: string;
  APPLE_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  // Vars (wrangler.toml [vars]; every deploy sets them from the file)
  BUNDLE_IDS?: string;
  APP_ATTEST_ENV?: string;
  ALLOW_DEV_TOKEN?: string;
  RATE_LIMIT_PER_MIN?: string;
  APNS_BUNDLE_ID?: string;
  APNS_ENV?: string;
  SESSION_TTL_SECONDS?: string;
  SESSION_MODELS?: string;
  SESSION_DAILY_LIMIT?: string;
  ATTEST_DAILY_PER_IP?: string;
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

/** Everything a test needs to replace: the clock, outbound fetch, the App Attest trust anchor, sleeping. */
export interface Deps {
  now: () => number;
  fetch: FetchLike;
  rootCaPem: string;
  sleep: (ms: number) => Promise<void>;
}

/** Only the app attests: App Attest does not work in app extensions (the notification extension uses a session). */
export const DEFAULT_BUNDLE_IDS = ["com.smartschedules.app"];

export function bundleIds(env: Env): string[] {
  const raw = env.BUNDLE_IDS?.trim();
  if (!raw) return DEFAULT_BUNDLE_IDS;
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

export function rateLimitPerMinute(env: Env): number {
  const n = Number(env.RATE_LIMIT_PER_MIN);
  return Number.isInteger(n) && n > 0 ? n : 30;
}

export const DEFAULT_SESSION_TTL_SECONDS = 7 * 24 * 3600;

/** Lifetime of an extension session token; KV needs at least 60 s. */
export function sessionTtlSeconds(env: Env): number {
  const n = Number(env.SESSION_TTL_SECONDS);
  return Number.isInteger(n) && n >= 60 ? n : DEFAULT_SESSION_TTL_SECONDS;
}

/**
 * Fallback for SESSION_MODELS. Must include the GEMINI_MODEL_ID (Config/Base.xcconfig) of every app version still in
 * use: add a new ID (and deploy) before submitting the build that uses it — App Review tests the notification
 * extension — and remove an old one only once no supported build sends it, or Google has shut it down. Never a prefix.
 * test/config-sync.test.ts checks that the current GEMINI_MODEL_ID is listed here and in wrangler.toml.
 */
// gemini-3.8-flash: the app since 2026-10-17. gemini-3.5-flash: the builds before it (still on testers' iPhones).
export const DEFAULT_SESSION_MODELS = ["gemini-3.8-flash", "gemini-3.5-flash"];

/** Models a Session token may call (POST …/models/<model>:generateContent only). */
export function sessionModels(env: Env): string[] {
  const list = (env.SESSION_MODELS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return list.length ? list : DEFAULT_SESSION_MODELS;
}

function positiveInt(value: string | undefined, fallback: number): number {
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

/** Session-authenticated generateContent calls per identity per UTC day (the extension makes 1–3 per reply). */
export function sessionDailyLimit(env: Env): number {
  return positiveInt(env.SESSION_DAILY_LIMIT, 200);
}

/** Successful attestations per client IP bucket per UTC day (high: carriers put many users behind one IPv4). */
export function attestDailyPerIp(env: Env): number {
  return positiveInt(env.ATTEST_DAILY_PER_IP, 200);
}

export function attestEnvironment(env: Env): AttestEnvironment | null {
  return env.APP_ATTEST_ENV === "development" || env.APP_ATTEST_ENV === "production" ? env.APP_ATTEST_ENV : null;
}

/** Apple Developer Team IDs are 10 upper-case alphanumerics. */
export function teamId(env: Env): string | null {
  const id = env.APPLE_TEAM_ID?.trim() ?? "";
  return /^[A-Z0-9]{10}$/.test(id) ? id : null;
}

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}
