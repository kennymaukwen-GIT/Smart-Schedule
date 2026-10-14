// APNs provider authentication token: JWT ES256 signed with the .p8 key (PKCS#8, P-256) via WebCrypto.
// header {alg:"ES256", kid:APNS_KEY_ID}, claims {iss:APNS_TEAM_ID, iat}. Apple accepts a token for up to an hour
// and rejects refreshing more often than every 20 minutes, so one token is reused for at most 50 minutes —
// cached in module scope (per isolate) and in KV `apns:jwt` (shared by all isolates).

import { b64decode, b64urlEncode, utf8 } from "./encoding.ts";
import type { Deps, Env } from "./env.ts";
import { ConfigError } from "./env.ts";
import { log } from "./http.ts";

export const JWT_MAX_AGE_SECONDS = 50 * 60;
export const JWT_KV_KEY = "apns:jwt";

interface CachedJwt {
  token: string;
  iat: number;
  kid: string;
  iss: string;
}

let memoryCache: CachedJwt | null = null;
let keyCache: { pem: string; key: CryptoKey } | null = null;

/** Imports the .p8 text (PEM "PRIVATE KEY", PKCS#8). Tolerates "\n" escapes from secrets pasted on one line. */
export async function importP8(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const der = b64decode(body);
  if (!der) throw new ConfigError("APNS_PRIVATE_KEY is not a PEM PKCS#8 key");
  return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/** Compact JWS with ES256 (WebCrypto ECDSA output is already the raw r ‖ s that JWS requires). */
export async function signEs256(header: Record<string, unknown>, claims: Record<string, unknown>, key: CryptoKey): Promise<string> {
  const signingInput = `${b64urlEncode(utf8(JSON.stringify(header)))}.${b64urlEncode(utf8(JSON.stringify(claims)))}`;
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(signingInput)));
  return `${signingInput}.${b64urlEncode(signature)}`;
}

function usable(entry: CachedJwt | null, kid: string, iss: string, nowSeconds: number): entry is CachedJwt {
  return (
    entry !== null &&
    entry.kid === kid &&
    entry.iss === iss &&
    entry.iat <= nowSeconds + 60 &&
    nowSeconds - entry.iat < JWT_MAX_AGE_SECONDS
  );
}

export async function apnsJwt(env: Env, deps: Deps): Promise<string> {
  const kid = env.APNS_KEY_ID?.trim();
  const iss = env.APNS_TEAM_ID?.trim();
  if (!kid || !iss || !env.APNS_PRIVATE_KEY) throw new ConfigError("APNS_KEY_ID, APNS_TEAM_ID and APNS_PRIVATE_KEY must be set");
  const nowSeconds = Math.floor(deps.now() / 1000);

  if (usable(memoryCache, kid, iss, nowSeconds)) return memoryCache.token;

  try {
    const shared = await env.SS_KV.get(JWT_KV_KEY);
    const parsed = shared ? (JSON.parse(shared) as CachedJwt) : null;
    if (usable(parsed, kid, iss, nowSeconds)) {
      memoryCache = parsed;
      return parsed.token;
    }
  } catch (e) {
    log("warn", "apns_jwt_cache_read_failed", { error: String(e) });
  }

  if (keyCache?.pem !== env.APNS_PRIVATE_KEY) {
    keyCache = { pem: env.APNS_PRIVATE_KEY, key: await importP8(env.APNS_PRIVATE_KEY) };
  }
  const token = await signEs256({ alg: "ES256", kid }, { iss, iat: nowSeconds }, keyCache.key);
  memoryCache = { token, iat: nowSeconds, kid, iss };
  try {
    await env.SS_KV.put(JWT_KV_KEY, JSON.stringify(memoryCache), { expirationTtl: JWT_MAX_AGE_SECONDS });
  } catch (e) {
    log("warn", "apns_jwt_cache_write_failed", { error: String(e) });
  }
  return token;
}

/** After APNs rejects the token (ExpiredProviderToken / InvalidProviderToken), mint a new one next time. */
export async function invalidateApnsJwt(env: Env): Promise<void> {
  memoryCache = null;
  try {
    await env.SS_KV.delete(JWT_KV_KEY);
  } catch (e) {
    log("warn", "apns_jwt_cache_delete_failed", { error: String(e) });
  }
}

/** Test hook: forget the module-scope caches. */
export function resetJwtCacheForTests(): void {
  memoryCache = null;
  keyCache = null;
}
