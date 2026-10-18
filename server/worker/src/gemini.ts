// ANY /v1beta/* → https://generativelanguage.googleapis.com/v1beta/* with the server's API key.
//
// The body is forwarded byte for byte (the same bytes the assertion's clientDataHash covered); nothing in it is
// parsed or rewritten. Path and query are kept, except any `key` query parameter. The upstream status, body and
// content-type come back unchanged: streamed, so SSE works, except a generateContent JSON answer, which is read in
// full first so its usageMetadata can be logged (`gemini_usage`: token counts and the cost, never any text).

import type { Deps, Env } from "./env.ts";
import { HttpError, log, parseJson } from "./http.ts";
import { costUSD, finishReasonOf, geminiPrices, modelOf, usageOf } from "./usage.ts";

export const GEMINI_ORIGIN = "https://generativelanguage.googleapis.com";

/**
 * The only client headers forwarded. Everything else stays here: credentials (Authorization, X-Dev-Token, cookies, a
 * client's own x-goog-api-key), hop-by-hop headers, and whatever identifies the user or the device (User-Agent with
 * the app build and iOS version, Accept-Language, cf-* location, forwarding addresses).
 */
const FORWARDED_HEADERS = new Set(["content-type", "accept"]);

/** Removes every `key` parameter while leaving the rest of the query string byte-identical. */
export function stripKeyParam(search: string): string {
  if (!search || search === "?") return "";
  const kept = search
    .slice(1)
    .split("&")
    .filter((pair) => {
      const rawName = pair.split("=", 1)[0]!;
      let name = rawName;
      try {
        name = decodeURIComponent(rawName.replace(/\+/g, " "));
      } catch {
        // malformed escapes: compare the raw name
      }
      return name !== "key";
    });
  return kept.length ? `?${kept.join("&")}` : "";
}

export async function proxyGemini(request: Request, body: Uint8Array, env: Env, deps: Deps): Promise<Response> {
  if (!env.GEMINI_API_KEY) {
    log("error", "server_misconfigured", { reason: "GEMINI_API_KEY secret is not set" });
    throw new HttpError(500, "server_misconfigured");
  }
  const url = new URL(request.url);
  const upstreamUrl = `${GEMINI_ORIGIN}${url.pathname}${stripKeyParam(url.search)}`;

  const headers = new Headers();
  request.headers.forEach((value, name) => {
    if (FORWARDED_HEADERS.has(name.toLowerCase())) headers.set(name, value);
  });
  headers.set("x-goog-api-key", env.GEMINI_API_KEY);

  const method = request.method.toUpperCase();
  const init: RequestInit = { method, headers, redirect: "manual" };
  if (method !== "GET" && method !== "HEAD") init.body = body;

  let upstream: Response;
  try {
    upstream = await deps.fetch(upstreamUrl, init);
  } catch (e) {
    log("error", "gemini_unreachable", { error: String(e) });
    throw new HttpError(502, "upstream_unavailable");
  }
  const responseHeaders = new Headers({ "cache-control": "no-store" });
  const contentType = upstream.headers.get("content-type");
  if (contentType) responseHeaders.set("content-type", contentType);

  const pathModel = method === "POST" ? generateContentModel(url.pathname) : undefined;
  if (pathModel === undefined) {
    return new Response(upstream.body, { status: upstream.status, headers: responseHeaders });
  }
  if (!upstream.ok) {
    // Google does not bill refused requests (400, 401/403, 429, 5xx); the status says which it was.
    log("warn", "gemini_refused", { model: pathModel, status: upstream.status });
    return new Response(upstream.body, { status: upstream.status, headers: responseHeaders });
  }
  let bytes: Uint8Array;
  try {
    bytes = new Uint8Array(await upstream.arrayBuffer());
  } catch (e) {
    log("error", "gemini_unreachable", { error: String(e) });
    throw new HttpError(502, "upstream_unavailable");
  }
  logUsage(parseJson(bytes), pathModel, env);
  return new Response(bytes, { status: upstream.status, headers: responseHeaders });
}

/** The model of `POST /v1beta/models/<model>:generateContent`; undefined for every other path (streams included). */
export function generateContentModel(pathname: string): string | undefined {
  const match = /^\/v1beta\/models\/([^/:]+):generateContent$/.exec(pathname);
  return match?.[1];
}

/** One line per billed answer: what it cost and why, from the counts Google returns. Never the request or answer. */
function logUsage(response: unknown, pathModel: string, env: Env): void {
  const usage = usageOf(response);
  if (!usage) {
    log("warn", "gemini_usage_missing", { model: pathModel });
    return;
  }
  log("info", "gemini_usage", {
    model: modelOf(response, pathModel),
    finish: finishReasonOf(response) ?? null,
    prompt: usage.prompt,
    cached: usage.cached,
    output: usage.output,
    thoughts: usage.thoughts,
    ...(usage.image ? { image: usage.image } : {}),
    ...(usage.document ? { document: usage.document } : {}),
    ...(usage.toolPrompt ? { toolPrompt: usage.toolPrompt } : {}),
    usd: costUSD(usage, geminiPrices(env)),
  });
}
