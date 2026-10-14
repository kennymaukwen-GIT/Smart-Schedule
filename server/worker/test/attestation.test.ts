import assert from "node:assert/strict";
import { before, describe, it } from "node:test";
import { AAGUID_DEVELOPMENT, AAGUID_PRODUCTION, AttestationError, loadRoot, verifyAttestation } from "../src/attestation.ts";
import type { AttestationInput } from "../src/attestation.ts";
import { concat, sha256, utf8 } from "../src/encoding.ts";
import type { AttestationOptions, Chain } from "./helpers/app-attest.ts";
import { APP_ID, makeAttestation, makeChain, rawPublicKey } from "./helpers/app-attest.ts";

const NOW = Date.UTC(2026, 9, 15, 8, 0, 0);
const CHALLENGE = crypto.getRandomValues(new Uint8Array(32));

describe("App Attest attestation verification", () => {
  let chain: Chain;
  let otherChain: Chain;

  before(async () => {
    chain = await makeChain(NOW);
    otherChain = await makeChain(NOW, "Impostor");
  });

  async function attempt(options: Partial<AttestationOptions> = {}, input: Partial<AttestationInput> = {}) {
    const a = await makeAttestation({ chain, now: NOW, challenge: CHALLENGE, ...options });
    const result = verifyAttestation({
      keyId: a.keyId,
      attestation: a.attestation,
      challenge: CHALLENGE,
      appId: APP_ID,
      environment: "development",
      root: loadRoot(chain.root.pem),
      now: NOW,
      ...input,
    });
    return { a, result };
  }

  async function expectFailure(reason: RegExp, options: Partial<AttestationOptions> = {}, input: Partial<AttestationInput> = {}) {
    const { result } = await attempt(options, input);
    await assert.rejects(result, (e: unknown) => {
      assert.ok(e instanceof AttestationError, `expected AttestationError, got ${String(e)}`);
      assert.match(e.message, reason);
      return true;
    });
  }

  it("accepts a valid development attestation and returns the credential public key", async () => {
    const { a, result } = await attempt();
    const verified = await result;
    assert.deepEqual(verified.publicKey, await rawPublicKey(a.credentialKeys.publicKey));
    assert.deepEqual(verified.receipt, utf8("test receipt"));
  });

  it("accepts a valid production attestation when APP_ATTEST_ENV is production", async () => {
    const { result } = await attempt({ environment: "production" }, { environment: "production" });
    await result;
  });

  it("checks the aaguid constants", () => {
    assert.equal(new TextDecoder().decode(AAGUID_DEVELOPMENT), "appattestdevelop");
    assert.deepEqual(AAGUID_PRODUCTION, concat(utf8("appattest"), new Uint8Array(7)));
  });

  it("rejects a wrong nonce (attested over a different challenge)", async () => {
    const other = await sha256(concat(new Uint8Array(10), crypto.getRandomValues(new Uint8Array(32))));
    await expectFailure(/nonce mismatch/, { nonceOverride: other });
  });

  it("rejects when the server's challenge differs from the attested one", async () => {
    await expectFailure(/nonce mismatch/, {}, { challenge: crypto.getRandomValues(new Uint8Array(32)) });
  });

  it("rejects a wrong appId (rpIdHash of another team/bundle)", async () => {
    await expectFailure(/rpIdHash/, { appId: "ZZZZZ99999.com.example.other" });
  });

  it("rejects a keyId that does not hash the credential key", async () => {
    await expectFailure(/keyId does not match/, {}, { keyId: crypto.getRandomValues(new Uint8Array(32)) });
  });

  it("rejects a nonzero counter", async () => {
    await expectFailure(/sign count is 1/, { counter: 1 });
  });

  it("rejects a development aaguid in production and a production aaguid in development", async () => {
    await expectFailure(/aaguid/, { environment: "development" }, { environment: "production" });
    await expectFailure(/aaguid/, { environment: "production" }, { environment: "development" });
  });

  it("rejects a credentialId that is not the keyId", async () => {
    await expectFailure(/credentialId/, { credentialId: crypto.getRandomValues(new Uint8Array(32)) });
  });

  it("rejects a chain that leads to a different root", async () => {
    await expectFailure(/not issued by root|signature invalid/, {}, { root: loadRoot(otherChain.root.pem) });
  });

  it("rejects an impostor intermediate with the same name as the real one", async () => {
    const impostor = await makeChain(NOW); // same subject names, different keys
    const a = await makeAttestation({ chain: impostor, now: NOW, challenge: CHALLENGE });
    await assert.rejects(
      verifyAttestation({ keyId: a.keyId, attestation: a.attestation, challenge: CHALLENGE, appId: APP_ID, environment: "development", root: loadRoot(chain.root.pem), now: NOW }),
      (e: unknown) => e instanceof AttestationError && /intermediate signature invalid/.test(e.message),
    );
  });

  it("rejects an expired credential certificate", async () => {
    await expectFailure(/expired/, { leafNotBefore: NOW - 10 * 86400_000, leafNotAfter: NOW - 86400_000 });
  });

  it("rejects a certificate that is not yet valid", async () => {
    await expectFailure(/not yet valid/, { leafNotBefore: NOW + 3600_000 });
  });

  it("rejects when verified after the intermediate expired", async () => {
    await expectFailure(/expired/, {}, { now: NOW + 6 * 365 * 86400_000 });
  });

  it("rejects malformed attestation objects", async () => {
    const base = { keyId: new Uint8Array(32), challenge: CHALLENGE, appId: APP_ID, environment: "development" as const, root: loadRoot(chain.root.pem), now: NOW };
    await assert.rejects(verifyAttestation({ ...base, attestation: new Uint8Array([0xa0]) }), AttestationError);
    await assert.rejects(verifyAttestation({ ...base, attestation: new Uint8Array([0xff, 0x00]) }), AttestationError);
  });
});
