// Refuses to continue (exit 1) until src/apple-root-ca.ts holds a PEM certificate. Used by `npm run deploy`.
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../src/apple-root-ca.ts", import.meta.url), "utf8");
const match = /APPLE_APP_ATTESTATION_ROOT_CA_PEM\s*=\s*`([^`]*)`/.exec(source);
const pem = match?.[1] ?? "";
if (!/-----BEGIN CERTIFICATE-----[\s\S]+-----END CERTIFICATE-----/.test(pem)) {
  console.error(
    "The Apple App Attestation Root CA is not embedded in src/apple-root-ca.ts.\n" +
      "Run `npm run embed-root-ca` (downloads it from https://www.apple.com/certificateauthority/), check the\n" +
      "printed SHA-256 fingerprint, record it in README.md, then deploy again.",
  );
  process.exit(1);
}
const fingerprint = /SHA-256 fingerprint: ([0-9A-F:]{95})/.exec(source)?.[1];
console.log(`Apple App Attestation Root CA embedded${fingerprint ? ` (SHA-256 ${fingerprint})` : ""}.`);
