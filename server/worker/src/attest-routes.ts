// GET /attest/challenge and POST /attest.

import { AttestationError, loadRoot, verifyAttestation } from "./attestation.ts";
import type { KeyRecord } from "./auth.ts";
import { keyRecordKey } from "./auth.ts";
import { b64decode, b64encode } from "./encoding.ts";
import type { Deps, Env } from "./env.ts";
import { attestEnvironment, bundleIds, teamId } from "./env.ts";
import { HttpError, json, log, parseJson, readBody } from "./http.ts";
import type { Certificate } from "./x509.ts";

const CHALLENGE_TTL_SECONDS = 300;
const MAX_ATTEST_BODY = 64 * 1024;

export function challengeKey(challenge: string): string {
  return `chal:${challenge}`;
}

export async function handleChallenge(env: Env): Promise<Response> {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const challenge = b64encode(bytes);
  await env.SS_KV.put(challengeKey(challenge), "1", { expirationTtl: CHALLENGE_TTL_SECONDS });
  return json(200, { challenge });
}

let cachedRoot: { pem: string; cert: Certificate } | null = null;

function trustAnchor(pem: string): Certificate {
  if (!pem.trim()) {
    log("error", "server_misconfigured", { reason: "Apple App Attestation Root CA is not embedded (src/apple-root-ca.ts)" });
    throw new HttpError(500, "server_misconfigured");
  }
  if (cachedRoot?.pem !== pem) cachedRoot = { pem, cert: loadRoot(pem) };
  return cachedRoot.cert;
}

interface AttestBody {
  keyId: string;
  attestation: string;
  challenge: string;
  bundleId: string;
}

function isAttestBody(value: unknown): value is AttestBody {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  return ["keyId", "attestation", "challenge", "bundleId"].every((k) => typeof v[k] === "string");
}

function reject(reason: string, fields: Record<string, unknown> = {}): never {
  log("warn", "attestation_rejected", { reason, ...fields });
  throw new HttpError(401, "invalid_attestation");
}

export async function handleAttest(request: Request, env: Env, deps: Deps): Promise<Response> {
  const body = parseJson(await readBody(request, MAX_ATTEST_BODY));
  if (!isAttestBody(body)) throw new HttpError(400, "invalid_request");

  const team = teamId(env);
  const environment = attestEnvironment(env);
  if (!team || !environment) {
    log("error", "server_misconfigured", { reason: "APPLE_TEAM_ID or APP_ATTEST_ENV is not set correctly" });
    throw new HttpError(500, "server_misconfigured");
  }
  const root = trustAnchor(deps.rootCaPem);

  // The challenge must be one we issued and is single use.
  const challengeBytes = b64decode(body.challenge);
  if (!challengeBytes || challengeBytes.length !== 32) throw new HttpError(401, "invalid_challenge");
  const stored = await env.SS_KV.get(challengeKey(body.challenge));
  if (stored === null) throw new HttpError(401, "invalid_challenge");
  await env.SS_KV.delete(challengeKey(body.challenge));

  if (!bundleIds(env).includes(body.bundleId)) reject("bundleId not allowed", { bundleId: body.bundleId.slice(0, 100) });
  const appId = `${team}.${body.bundleId}`;

  const keyIdBytes = b64decode(body.keyId);
  if (!keyIdBytes || keyIdBytes.length !== 32) reject("keyId is not base64 of 32 bytes");
  const attestation = b64decode(body.attestation);
  if (!attestation) reject("attestation is not base64");
  const keyId = b64encode(keyIdBytes); // canonical form; equals what the Bearer token's first 32 bytes encode to

  let publicKey: Uint8Array;
  try {
    ({ publicKey } = await verifyAttestation({
      keyId: keyIdBytes,
      attestation,
      challenge: challengeBytes,
      appId,
      environment,
      root,
      now: deps.now(),
    }));
  } catch (e) {
    if (e instanceof AttestationError) reject(e.message, { keyId });
    throw e;
  }

  // A key already on file keeps its counter, so a repeated attestation never re-opens old assertions.
  let counter = 0;
  const existing = await env.SS_KV.get(keyRecordKey(keyId));
  if (existing !== null) {
    try {
      const previous = JSON.parse(existing) as Partial<KeyRecord>;
      if (Number.isInteger(previous.counter) && (previous.counter as number) > 0) counter = previous.counter as number;
    } catch {
      // unreadable record: overwrite
    }
  }
  const record: KeyRecord = {
    publicKey: b64encode(publicKey),
    counter,
    appId,
    createdAt: new Date(deps.now()).toISOString(),
  };
  await env.SS_KV.put(keyRecordKey(keyId), JSON.stringify(record));
  log("info", "key_attested", { keyId, appId, environment });
  return json(200, { ok: true });
}
