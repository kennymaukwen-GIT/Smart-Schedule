// Cross-checks between the app's build settings and the Worker's configuration (CI runs this on a full checkout).

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import type { Env } from "../src/env.ts";
import { DEFAULT_SESSION_MODELS, sessionModels } from "../src/env.ts";

/** A file of this repository, relative to its root (this file is server/worker/test/). */
function repoFile(path: string): string {
  return readFileSync(new URL(`../../../${path}`, import.meta.url), "utf8");
}

function match(text: string, pattern: RegExp, what: string): string {
  const m = pattern.exec(text);
  assert.ok(m?.[1], `${what} not found`);
  return m[1];
}

describe("app ↔ Worker configuration", () => {
  it("SESSION_MODELS (wrangler.toml and the built-in default) includes the app's GEMINI_MODEL_ID", () => {
    const model = match(repoFile("Config/Base.xcconfig"), /^[ \t]*GEMINI_MODEL_ID[ \t]*=[ \t]*([^\s/]+)/m, "GEMINI_MODEL_ID in Config/Base.xcconfig");
    const configured = match(repoFile("server/worker/wrangler.toml"), /^[ \t]*SESSION_MODELS[ \t]*=[ \t]*"([^"]*)"/m, "SESSION_MODELS in wrangler.toml");
    const listed = sessionModels({ SESSION_MODELS: configured } as unknown as Env);
    assert.ok(
      listed.includes(model),
      `wrangler.toml SESSION_MODELS (${listed.join(",")}) must include the app's GEMINI_MODEL_ID ${model}: add it (keeping the IDs of app versions still in use) and deploy the Worker before shipping the build`,
    );
    assert.ok(DEFAULT_SESSION_MODELS.includes(model), `DEFAULT_SESSION_MODELS in src/env.ts must include ${model}`);
  });

  it("the Rate Limiting binding's simple.limit equals RATE_LIMIT_PER_MIN", () => {
    const toml = repoFile("server/worker/wrangler.toml");
    const binding = match(toml, /^simple[ \t]*=[ \t]*\{[^}]*\blimit[ \t]*=[ \t]*(\d+)/m, "[[ratelimits]] simple.limit");
    const perMinute = match(toml, /^[ \t]*RATE_LIMIT_PER_MIN[ \t]*=[ \t]*"(\d+)"/m, "RATE_LIMIT_PER_MIN");
    assert.equal(binding, perMinute);
  });
});
