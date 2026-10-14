// A Worker wired to an in-memory KV, a controllable clock and a recording fetch mock.

import type { Env } from "../../src/env.ts";
import type { Worker } from "../../src/index.ts";
import { createWorker } from "../../src/index.ts";
import { MemoryKV } from "./memory-kv.ts";
import { TEAM_ID } from "./app-attest.ts";

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
  env: Env;
  worker: Worker;
  calls: FetchCall[];
  respond: FetchResponder;
  setResponder(responder: FetchResponder): void;
  request(path: string, init?: RequestInit): Promise<Response>;
  runCron(): Promise<void>;
}

export const START = Date.UTC(2026, 9, 15, 8, 0, 0); // 2026-10-15T08:00:00Z

export function makeHarness(options: { rootCaPem?: string; env?: Partial<Env>; now?: number } = {}): Harness {
  const clock = { now: options.now ?? START };
  const kv = new MemoryKV(() => clock.now);
  const env: Env = {
    SS_KV: kv,
    GEMINI_API_KEY: "test-gemini-key",
    SS_DEV_TOKEN: "dev-secret-token",
    APPLE_TEAM_ID: TEAM_ID,
    BUNDLE_IDS: "com.smartschedule.app,com.smartschedule.app.notification-content",
    APP_ATTEST_ENV: "development",
    ALLOW_DEV_TOKEN: "false",
    RATE_LIMIT_PER_MIN: "30",
    APNS_KEY_ID: "KEYID12345",
    APNS_TEAM_ID: TEAM_ID,
    APNS_BUNDLE_ID: "com.smartschedule.app",
    APNS_ENV: "sandbox",
    ...options.env,
  };
  const calls: FetchCall[] = [];
  const harness: Harness = {
    clock,
    kv,
    env,
    calls,
    respond: () => new Response("{}", { status: 200, headers: { "content-type": "application/json" } }),
    setResponder(responder) {
      harness.respond = responder;
    },
    worker: createWorker({
      now: () => clock.now,
      rootCaPem: options.rootCaPem ?? "",
      sleep: async () => {},
      fetch: async (input, init) => {
        const body = init?.body === undefined || init.body === null ? null : new Uint8Array(await new Response(init.body).arrayBuffer());
        const call: FetchCall = { url: input, method: init?.method ?? "GET", headers: new Headers(init?.headers), body };
        calls.push(call);
        return harness.respond(call);
      },
    }),
    request(path, init) {
      return harness.worker.fetch(new Request(`https://worker.test${path}`, init), env, { waitUntil() {} });
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
