import assert from "node:assert/strict";
import { X509Certificate as NodeX509 } from "node:crypto";
import { before, describe, it } from "node:test";
import * as x509 from "@peculiar/x509";
import { DerError, decodeOid, decodeTime, ecdsaDerToRaw, parseDer } from "../src/der.ts";
import { CertificateError, OID, parseCertificate, pemToDer, verifyChain, verifySignedBy } from "../src/x509.ts";
import type { Chain } from "./helpers/app-attest.ts";
import { NONCE_OID, makeAttestation, makeChain, rawToDerSignature } from "./helpers/app-attest.ts";
import { generateEcKeyPair } from "./helpers/webcrypto.ts";

const NOW = Date.UTC(2026, 9, 15, 8, 0, 0);

function hexBytes(h: string): Uint8Array {
  return new Uint8Array(h.match(/../g)!.map((b) => parseInt(b, 16)));
}

describe("DER primitives", () => {
  it("decodes OIDs", () => {
    assert.equal(decodeOid(parseDer(hexBytes("06072a8648ce3d0201"))), "1.2.840.10045.2.1");
    assert.equal(decodeOid(parseDer(hexBytes("06082a8648ce3d030107"))), "1.2.840.10045.3.1.7");
    assert.equal(decodeOid(parseDer(hexBytes("06052b81040022"))), "1.3.132.0.34");
    assert.equal(decodeOid(parseDer(hexBytes("06092a864886f763640802"))), NONCE_OID);
  });

  it("rejects non-DER lengths, indefinite lengths and trailing bytes", () => {
    assert.throws(() => parseDer(hexBytes("04810100")), DerError); // long form for a short length
    assert.throws(() => parseDer(hexBytes("3080")), DerError);
    assert.throws(() => parseDer(hexBytes("040100ff")), DerError);
    assert.throws(() => parseDer(hexBytes("0405010203")), DerError);
  });

  it("parses UTCTime and GeneralizedTime", () => {
    assert.equal(decodeTime(parseDer(hexBytes("170d3236313031353038303030305a"))), NOW); // 261015080000Z
    assert.equal(decodeTime(parseDer(hexBytes("180f32303530303130313030303030305a"))), Date.UTC(2050, 0, 1));
    assert.throws(() => decodeTime(parseDer(hexBytes("170d3236303233313030303030305a"))), DerError); // Feb 31
  });

  it("converts DER ECDSA signatures to raw r ‖ s", () => {
    const raw = crypto.getRandomValues(new Uint8Array(64));
    raw[0] = 0x80; // forces a leading zero in DER
    raw[32] = 0x00;
    raw[33] = 0x05; // short s
    assert.deepEqual(ecdsaDerToRaw(rawToDerSignature(raw), 32), raw);
    assert.throws(() => ecdsaDerToRaw(hexBytes("3006020100020101"), 32), DerError); // r = 0
    assert.throws(() => ecdsaDerToRaw(hexBytes("30060201ff020101"), 32), DerError); // negative r
  });
});

describe("X.509 parsing and chain verification", () => {
  let chain: Chain;
  let leafDer: Uint8Array;

  before(async () => {
    chain = await makeChain(NOW);
    const a = await makeAttestation({ chain, now: NOW, challenge: new Uint8Array(32) });
    leafDer = new Uint8Array(a.leaf.rawData);
  });

  it("agrees with OpenSSL (node:crypto) on names, validity and keys", () => {
    for (const der of [leafDer, new Uint8Array(chain.intermediate.cert.rawData), new Uint8Array(chain.root.cert.rawData)]) {
      const ours = parseCertificate(der);
      const theirs = new NodeX509(der);
      assert.equal(ours.notBefore, Date.parse(theirs.validFrom));
      assert.equal(ours.notAfter, Date.parse(theirs.validTo));
      const spki = new Uint8Array(theirs.publicKey.export({ type: "spki", format: "der" }));
      assert.deepEqual(spki.subarray(spki.length - ours.publicKey.length), ours.publicKey);
    }
    const leaf = parseCertificate(leafDer);
    assert.equal(leaf.curve, OID.p256);
    assert.equal(leaf.signatureAlgorithm, OID.ecdsaWithSHA256);
    assert.equal(leaf.extensions.get(NONCE_OID)?.value.length, 38);
    assert.equal(leaf.basicConstraints?.ca, false);
    const intermediate = parseCertificate(new Uint8Array(chain.intermediate.cert.rawData));
    assert.equal(intermediate.curve, OID.p384);
    assert.deepEqual(intermediate.basicConstraints, { ca: true, pathLen: 0 });
    // OpenSSL agrees that the leaf was issued by the intermediate.
    assert.ok(new NodeX509(leafDer).checkIssued(new NodeX509(new Uint8Array(chain.intermediate.cert.rawData))));
  });

  it("verifies a good chain (SHA-256 by P-384, SHA-384 by P-384)", async () => {
    const root = parseCertificate(pemToDer(chain.root.pem));
    await verifyChain(parseCertificate(leafDer), parseCertificate(new Uint8Array(chain.intermediate.cert.rawData)), root, NOW);
  });

  it("detects a tampered signature", async () => {
    const tampered = leafDer.slice();
    tampered[tampered.length - 5]! ^= 0x01;
    const leaf = parseCertificate(tampered);
    assert.equal(await verifySignedBy(leaf, parseCertificate(new Uint8Array(chain.intermediate.cert.rawData))), false);
  });

  it("rejects an unhandled critical extension", async () => {
    const leafCert = await x509.X509CertificateGenerator.create({
      serialNumber: "05",
      subject: "CN=critical",
      issuer: chain.intermediate.cert.subject,
      notBefore: new Date(NOW - 3600_000),
      notAfter: new Date(NOW + 3600_000),
      publicKey: (await generateEcKeyPair("P-256")).publicKey,
      signingKey: chain.intermediate.keys.privateKey,
      signingAlgorithm: { name: "ECDSA", hash: "SHA-256" },
      extensions: [new x509.Extension("1.2.3.4.5", true, hexBytes("0500"))],
    });
    await assert.rejects(
      verifyChain(
        parseCertificate(new Uint8Array(leafCert.rawData)),
        parseCertificate(new Uint8Array(chain.intermediate.cert.rawData)),
        parseCertificate(pemToDer(chain.root.pem)),
        NOW,
      ),
      (e: unknown) => e instanceof CertificateError && /unhandled critical extension 1\.2\.3\.4\.5/.test(e.message),
    );
  });

  it("rejects garbage as a certificate", () => {
    assert.throws(() => parseCertificate(hexBytes("3003020101")), CertificateError);
  });
});
