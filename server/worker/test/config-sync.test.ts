// Cross-checks between the app's build settings and the Worker's configuration (CI runs this on a full checkout).

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import type { Env } from "../src/env.ts";
import { bundleIds, DEFAULT_BUNDLE_IDS, DEFAULT_SESSION_MODELS, sessionModels } from "../src/env.ts";

/** A file of this repository, relative to its root (this file is server/worker/test/), with LF line endings. */
function repoFile(path: string): string {
  return readFileSync(new URL(`../../../${path}`, import.meta.url), "utf8").replace(/\r\n/g, "\n");
}

function match(text: string, pattern: RegExp, what: string): string {
  const m = pattern.exec(text);
  assert.ok(m?.[1], `${what} not found`);
  return m[1];
}

/** wrangler.toml split into the top level (production) and each [env.<name>] (its tables included). */
function wranglerEnvironments(): Map<string, string> {
  const toml = repoFile("server/worker/wrangler.toml");
  const parts = new Map<string, string>();
  let name = "production";
  let lines: string[] = [];
  for (const line of toml.split("\n")) {
    const env = /^\[+env\.([A-Za-z0-9_-]+)[\].]/.exec(line)?.[1];
    if (env && env !== name) {
      parts.set(name, (parts.get(name) ?? "") + lines.join("\n"));
      name = env;
      lines = [];
    }
    lines.push(line);
  }
  parts.set(name, (parts.get(name) ?? "") + lines.join("\n"));
  return parts;
}

describe("app ↔ Worker configuration", () => {
  it("SESSION_MODELS (every wrangler.toml environment and the built-in default) includes the app's GEMINI_MODEL_ID", () => {
    const model = match(repoFile("Config/Base.xcconfig"), /^[ \t]*GEMINI_MODEL_ID[ \t]*=[ \t]*([^\s/]+)/m, "GEMINI_MODEL_ID in Config/Base.xcconfig");
    for (const [name, toml] of wranglerEnvironments()) {
      const configured = match(toml, /^[ \t]*SESSION_MODELS[ \t]*=[ \t]*"([^"]*)"/m, `SESSION_MODELS in wrangler.toml (${name})`);
      const listed = sessionModels({ SESSION_MODELS: configured } as unknown as Env);
      assert.ok(
        listed.includes(model),
        `wrangler.toml SESSION_MODELS (${name}: ${listed.join(",")}) must include the app's GEMINI_MODEL_ID ${model}: add it (keeping the IDs of app versions still in use) and deploy the Worker before shipping the build`,
      );
    }
    assert.ok(DEFAULT_SESSION_MODELS.includes(model), `DEFAULT_SESSION_MODELS in src/env.ts must include ${model}`);
  });

  it("each environment's Rate Limiting binding has simple.limit equal to its RATE_LIMIT_PER_MIN", () => {
    for (const [name, toml] of wranglerEnvironments()) {
      const binding = match(toml, /^simple[ \t]*=[ \t]*\{[^}]*\blimit[ \t]*=[ \t]*(\d+)/m, `[[ratelimits]] simple.limit (${name})`);
      const perMinute = match(toml, /^[ \t]*RATE_LIMIT_PER_MIN[ \t]*=[ \t]*"(\d+)"/m, `RATE_LIMIT_PER_MIN (${name})`);
      assert.equal(binding, perMinute, name);
    }
  });

  it("the production Worker never accepts a dev token and the dev Worker is a Worker of its own", () => {
    const environments = wranglerEnvironments();
    const production = environments.get("production") ?? "";
    assert.equal(match(production, /^[ \t]*ALLOW_DEV_TOKEN[ \t]*=[ \t]*"([^"]*)"/m, "ALLOW_DEV_TOKEN"), "false");
    assert.equal(match(production, /^[ \t]*APP_ATTEST_ENV[ \t]*=[ \t]*"([^"]*)"/m, "APP_ATTEST_ENV"), "production");
    const dev = environments.get("dev");
    assert.ok(dev, "[env.dev] in wrangler.toml");
    const productionName = match(production, /^name[ \t]*=[ \t]*"([^"]+)"/m, "name");
    assert.notEqual(match(dev, /^name[ \t]*=[ \t]*"([^"]+)"/m, "[env.dev] name"), productionName);
    // Its own KV namespace (none of production's keys) and its own rate limiter.
    assert.ok(!/^id[ \t]*=/m.test(dev.split("[[env.dev.kv_namespaces]]")[1]?.split("[")[0] ?? ""), "[env.dev] KV must not reuse an id");
    const namespaceIDs = [...environments.values()].map((toml) => match(toml, /^namespace_id[ \t]*=[ \t]*"(\d+)"/m, "namespace_id"));
    assert.equal(new Set(namespaceIDs).size, namespaceIDs.length, "rate limiter namespace_id must differ per environment");
  });

  it("production runs no cron while the app has no aps-environment (version 1.0: no push-to-start, no APNs secrets)", () => {
    const project = repoFile("project.yml").replace(/(^|\s)#.*$/gm, "$1");
    const production = wranglerEnvironments().get("production") ?? "";
    const crons = match(production, /^\[triggers\]\ncrons[ \t]*=[ \t]*(\[[^\]\n]*\])/m, "[triggers] crons (production)");
    if (!/\baps-environment\b/.test(project)) {
      assert.equal(crons.replace(/\s/g, ""), "[]", "set crons = [] in wrangler.toml: without APNs every run only logs server_misconfigured");
    }
  });

  it("the Team ID, APNs IDs and keys are secrets: never assigned in wrangler.toml, where a deploy would reset them", () => {
    const toml = repoFile("server/worker/wrangler.toml");
    for (const name of ["GEMINI_API_KEY", "SS_DEV_TOKEN", "APNS_PRIVATE_KEY", "APPLE_TEAM_ID", "APNS_KEY_ID", "APNS_TEAM_ID"]) {
      assert.ok(!new RegExp(`^[ \\t]*${name}[ \\t]*=`, "m").test(toml), `${name} must not be in wrangler.toml: npx wrangler secret put ${name}`);
    }
  });

  it("each environment attests the app's bundle ID, pushes to it on its APNs host, and keeps invocation logs off", () => {
    const app = match(repoFile("project.yml"), /^  SmartSchedule:\n(?:(?!^  \S).*\n)*?[ \t]+PRODUCT_BUNDLE_IDENTIFIER:[ \t]*(\S+)/m, "SmartSchedule PRODUCT_BUNDLE_IDENTIFIER in project.yml");
    const expected = new Map([["production", { attest: "production", apns: "production" }], ["dev", { attest: "development", apns: "sandbox" }]]);
    const environments = wranglerEnvironments();
    assert.deepEqual([...environments.keys()].sort(), [...expected.keys()].sort());
    for (const [name, toml] of environments) {
      const value = (key: string) => match(toml, new RegExp(`^[ \\t]*${key}[ \\t]*=[ \\t]*"([^"]*)"`, "m"), `${key} (${name})`);
      assert.deepEqual(bundleIds({ BUNDLE_IDS: value("BUNDLE_IDS") } as unknown as Env), [app], `BUNDLE_IDS (${name})`);
      assert.equal(value("APNS_BUNDLE_ID"), app, `APNS_BUNDLE_ID (${name})`);
      assert.equal(value("APP_ATTEST_ENV"), expected.get(name)!.attest, `APP_ATTEST_ENV (${name})`);
      assert.equal(value("APNS_ENV"), expected.get(name)!.apns, `APNS_ENV (${name})`);
      assert.match(toml, /^\[(?:env\.[A-Za-z0-9_-]+\.)?observability\.logs\]\ninvocation_logs[ \t]*=[ \t]*false$/m, `invocation_logs = false (${name})`);
    }
    assert.deepEqual(DEFAULT_BUNDLE_IDS, [app]);
  });
});
