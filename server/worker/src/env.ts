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

export interface Env {
  SS_KV: KV;
  // Secrets (wrangler secret put …)
  GEMINI_API_KEY?: string;
  SS_DEV_TOKEN?: string;
  APNS_PRIVATE_KEY?: string;
  // Vars (wrangler.toml [vars])
  APPLE_TEAM_ID?: string;
  BUNDLE_IDS?: string;
  APP_ATTEST_ENV?: string;
  ALLOW_DEV_TOKEN?: string;
  RATE_LIMIT_PER_MIN?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_BUNDLE_ID?: string;
  APNS_ENV?: string;
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

/** Everything a test needs to replace: the clock, outbound fetch, the App Attest trust anchor, sleeping. */
export interface Deps {
  now: () => number;
  fetch: FetchLike;
  rootCaPem: string;
  sleep: (ms: number) => Promise<void>;
}

export const DEFAULT_BUNDLE_IDS = ["com.smartschedule.app", "com.smartschedule.app.notification-content"];

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
