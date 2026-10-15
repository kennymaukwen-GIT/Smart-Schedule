// ANY /v1beta/* → https://generativelanguage.googleapis.com/v1beta/* with the server's API key.
//
// The body is forwarded byte for byte (the same bytes the assertion's clientDataHash covered); nothing in it is
// parsed or rewritten. Path and query are kept, except any `key` query parameter. The upstream status, body
// (streamed, so SSE works) and content-type come back unchanged.

import type { Deps, Env } from "./env.ts";
import { HttpError, log } from "./http.ts";

export const GEMINI_ORIGIN = "https://generativelanguage.googleapis.com";

/** Never forwarded: client credentials, cookies, hop-by-hop headers and client-identifying headers (plus every cf-*). */
const STRIPPED_HEADERS = new Set([
  "authorization",
  "x-dev-token",
  "cookie",
  "x-goog-api-key",
  "host",
  "content-length",
  "connection",
  "keep-alive",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "cdn-loop",
  "true-client-ip",
  "x-forwarded-for",
  "x-forwarded-proto",
  "x-real-ip",
]);

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
    const lower = name.toLowerCase();
    if (!STRIPPED_HEADERS.has(lower) && !lower.startsWith("cf-")) headers.set(name, value);
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
  return new Response(upstream.body, { status: upstream.status, headers: responseHeaders });
}
