// A Worker wired to an in-memory KV, a controllable clock and a recording fetch mock.

import type { Env, RateLimiter } from "../../src/env.ts";
import type { Worker } from "../../src/index.ts";
import { createWorker } from "../../src/index.ts";
import { MemoryKV } from "./memory-kv.ts";
import { TEAM_ID } from "./app-attest.ts";

/** Stand-in for Cloudflare's Rate Limiting binding: an atomic fixed window per key and minute. */
export class FakeRateLimiter implements RateLimiter {
  readonly calls: string[] = [];
  readonly counts = new Map<string, number>();
  readonly perMinute: number;
  readonly clock: () => number;

  constructor(perMinute: number, clock: () => number) {
    this.perMinute = perMinute;
    this.clock = clock;
  }

  async limit({ key }: { key: string }): Promise<{ success: boolean }> {
    // Counted before any await: concurrent calls cannot all see the same count.
    const window = `${key}@${Math.floor(this.clock() / 60_000)}`;
    const n = (this.counts.get(window) ?? 0) + 1;
    this.counts.set(window, n);
    this.calls.push(key);
    return { success: n <= this.perMinute };
  }
}

export interface FetchCall {
  url: string;
  method: string;
  headers: Headers;
  body: Uint8Array | null;
}

export type FetchResponder = (call: FetchCall) => Response | Promise<Response>;

export interface Harness {
  clock: { now: number };
  kv: MemoryKV;
  /** The fake SS_RATE_LIMITER binding (null when the harness was made with rateLimiter: false). */
  limiter: FakeRateLimiter | null;
  env: Env;
  worker: Worker;
  calls: FetchCall[];
  respond: FetchResponder;
  setResponder(responder: FetchResponder): void;
  request(path: string, init?: RequestInit): Promise<Response>;
  runCron(): Promise<void>;
}

export const START = Date.UTC(2026, 9, 15, 8, 0, 0); // 2026-10-15T08:00:00Z

export function makeHarness(
  options: { rootCaPem?: string; env?: Partial<Env>; now?: number; sleep?: (ms: number) => Promise<void>; rateLimiter?: boolean } = {},
): Harness {
  const clock = { now: options.now ?? START };
  const kv = new MemoryKV(() => clock.now);
  // Like production, the Rate Limiting binding is bound by default, with simple.limit = RATE_LIMIT_PER_MIN.
  const limiter = options.rateLimiter === false ? null : new FakeRateLimiter(Number(options.env?.RATE_LIMIT_PER_MIN ?? "30"), () => clock.now);
  const env: Env = {
    SS_KV: kv,
    GEMINI_API_KEY: "test-gemini-key",
    SS_DEV_TOKEN: "dev-secret-token",
    APPLE_TEAM_ID: TEAM_ID,
    BUNDLE_IDS: "com.smartschedule.app",
    APP_ATTEST_ENV: "development",
    ALLOW_DEV_TOKEN: "false",
    RATE_LIMIT_PER_MIN: "30",
    APNS_KEY_ID: "KEYID12345",
    APNS_TEAM_ID: TEAM_ID,
    APNS_BUNDLE_ID: "com.smartschedule.app",
    APNS_ENV: "sandbox",
    ...options.env,
  };
  if (limiter) env.SS_RATE_LIMITER = limiter;
  const calls: FetchCall[] = [];
  const harness: Harness = {
    clock,
    kv,
    limiter,
    env,
    calls,
    respond: () => new Response("{}", { status: 200, headers: { "content-type": "application/json" } }),
    setResponder(responder) {
      harness.respond = responder;
    },
    worker: createWorker({
      now: () => clock.now,
      rootCaPem: options.rootCaPem ?? "",
      sleep: options.sleep ?? (async () => {}),
      fetch: async (input, init) => {
        const body = init?.body === undefined || init.body === null ? null : new Uint8Array(await new Response(init.body).arrayBuffer());
        const call: FetchCall = { url: input, method: init?.method ?? "GET", headers: new Headers(init?.headers), body };
        calls.push(call);
        return harness.respond(call);
      },
    }),
    request(path, init = {}) {
      // Like Cloudflare, give a fixed-size body its Content-Length (readBody's primary path).
      const headers = new Headers(init.headers);
      if ((typeof init.body === "string" || init.body instanceof Uint8Array) && !headers.has("content-length")) {
        headers.set("content-length", String(typeof init.body === "string" ? new TextEncoder().encode(init.body).length : init.body.byteLength));
      }
      return harness.worker.fetch(new Request(`https://worker.test${path}`, { ...init, headers }), env, { waitUntil() {} });
    },
    async runCron() {
      const pending: Promise<unknown>[] = [];
      await harness.worker.scheduled({ scheduledTime: clock.now, cron: "* * * * *" }, env, {
        waitUntil(p) {
          pending.push(p);
        },
      });
      await Promise.all(pending);
    },
  };
  return harness;
}

export async function jsonOf(response: Response): Promise<Record<string, unknown>> {
  return (await response.json()) as Record<string, unknown>;
}
