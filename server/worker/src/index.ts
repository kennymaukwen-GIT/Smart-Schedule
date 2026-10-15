// Smart Schedule Worker: App Attest–gated Gemini proxy and Live Activity push-to-start scheduler.
//
//   GET  /attest/challenge        one-time challenge (rate-limited per IP)
//   POST /attest                  verify an App Attest attestation, remember the key (rate-limited per IP)
//   POST /session                 assertion-authenticated → session token for the app's extension
//   ANY  /v1beta/*                assertion-authenticated → Gemini API with the server's key; a session token only
//                                 for POST /v1beta/models/<SESSION_MODELS>:generateContent
//   POST /devices/push-to-start   assertion-authenticated → store the device's push-to-start registration
//   cron * * * * *                send due push-to-start notifications

import { APPLE_APP_ATTESTATION_ROOT_CA_PEM } from "./apple-root-ca.ts";
import { handleAttest, handleChallenge } from "./attest-routes.ts";
import { authenticate } from "./auth.ts";
import { runCron } from "./cron.ts";
import type { Deps, Env, KV, RateLimiter } from "./env.ts";
import { sessionModels } from "./env.ts";
import { proxyGemini } from "./gemini.ts";
import { HttpError, errorResponse, log } from "./http.ts";
import {
  checkAttestDaily,
  clientIp,
  enforceIpLimit,
  enforceRateLimit,
  enforceSessionDailyLimit,
  recordAttestSuccess,
} from "./ratelimit.ts";
import { handlePushToStart } from "./registration.ts";
import { MAX_SESSION_BODY, handleSession } from "./session.ts";

export type { Env } from "./env.ts";

// Compile-time checks that the real bindings satisfy the subsets this Worker relies on.
export type KVNamespaceSatisfiesKV = KVNamespace extends KV ? true : never;
export type RateLimitSatisfiesRateLimiter = RateLimit extends RateLimiter ? true : never;
const _bindingCheck: [KVNamespaceSatisfiesKV, RateLimitSatisfiesRateLimiter] = [true, true];
void _bindingCheck;

/** The app sends text prompts; 2 MB leaves ample room and bounds what an unauthenticated caller can make us read. */
const MAX_GEMINI_BODY = 2 * 1024 * 1024;
/** The notification extension sends text prompts plus its tool declarations. */
const MAX_SESSION_GEMINI_BODY = 512 * 1024;
const MAX_REGISTRATION_BODY = 1024 * 1024;

export interface ScheduledEventLike {
  scheduledTime: number;
  cron: string;
}

export interface ExecutionContextLike {
  waitUntil(promise: Promise<unknown>): void;
}

export interface Worker {
  fetch(request: Request, env: Env, ctx: ExecutionContextLike): Promise<Response>;
  scheduled(event: ScheduledEventLike, env: Env, ctx: ExecutionContextLike): Promise<void>;
}

async function route(request: Request, env: Env, deps: Deps): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method.toUpperCase();

  if (path === "/attest/challenge") {
    if (method !== "GET") throw new HttpError(405, "method_not_allowed", { allow: "GET" });
    const bucket = clientIp(request);
    await enforceIpLimit(env, bucket, deps.now());
    await checkAttestDaily(env, bucket, deps.now());
    return handleChallenge(env);
  }

  if (path === "/attest") {
    if (method !== "POST") throw new HttpError(405, "method_not_allowed", { allow: "POST" });
    const bucket = clientIp(request);
    await enforceIpLimit(env, bucket, deps.now());
    await checkAttestDaily(env, bucket, deps.now());
    const response = await handleAttest(request, env, deps);
    if (response.status === 200) await recordAttestSuccess(env, bucket, deps.now()); // a new identity for this bucket
    return response;
  }

  if (path === "/session") {
    if (method !== "POST") throw new HttpError(405, "method_not_allowed", { allow: "POST" });
    const { identity, body, via } = await authenticate(request, env, deps, { maxBody: MAX_SESSION_BODY });
    await enforceRateLimit(env, identity.id, deps.now(), { strict: via !== "assertion" });
    return handleSession(body, identity, env, deps);
  }

  if (path.startsWith("/v1beta/")) {
    // The only route that accepts `Authorization: Session <token>`, and only for the extension's one call
    // (POST …/models/<SESSION_MODELS>:generateContent, ≤ 512 KB). Bearer and dev keep the full /v1beta/* passthrough.
    const { identity, body, via } = await authenticate(request, env, deps, {
      maxBody: MAX_GEMINI_BODY,
      session: { maxBody: MAX_SESSION_GEMINI_BODY, models: sessionModels(env) },
    });
    await enforceRateLimit(env, identity.id, deps.now(), { strict: via !== "assertion" });
    if (via === "session") await enforceSessionDailyLimit(env, identity.id, deps.now());
    return proxyGemini(request, body, env, deps);
  }

  if (path === "/devices/push-to-start") {
    if (method !== "POST") throw new HttpError(405, "method_not_allowed", { allow: "POST" });
    const { identity, body, via } = await authenticate(request, env, deps, { maxBody: MAX_REGISTRATION_BODY });
    await enforceRateLimit(env, identity.id, deps.now(), { strict: via !== "assertion" });
    return handlePushToStart(body, identity, env, deps);
  }

  throw new HttpError(404, "not_found");
}

export function createWorker(overrides: Partial<Deps> = {}): Worker {
  const deps: Deps = {
    now: () => Date.now(),
    fetch: (input, init) => fetch(input, init),
    rootCaPem: APPLE_APP_ATTESTATION_ROOT_CA_PEM,
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    ...overrides,
  };

  return {
    async fetch(request, env) {
      try {
        return await route(request, env, deps);
      } catch (e) {
        if (e instanceof HttpError) return errorResponse(e.status, e.code, e.headers);
        log("error", "unhandled_error", { error: e instanceof Error ? `${e.name}: ${e.message}` : String(e) });
        return errorResponse(500, "internal_error");
      }
    },

    async scheduled(_event, env, ctx) {
      ctx.waitUntil(
        runCron(env, deps).then(
          (summary) => {
            if (summary.indexed) log("info", "cron_done", { ...summary });
          },
          (e) => log("error", "cron_failed", { error: e instanceof Error ? `${e.name}: ${e.message}` : String(e) }),
        ),
      );
    },
  };
}

export default createWorker();
