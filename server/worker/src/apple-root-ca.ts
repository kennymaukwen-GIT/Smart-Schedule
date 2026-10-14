// Apple App Attestation Root CA — the only trust anchor for POST /attest.
//
// Source: https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
//
// NOT YET EMBEDDED. The build environment that wrote this Worker could not reach www.apple.com (egress policy
// denied the connection), and the certificate must never be typed in or copied from a third party. Until
// `npm run embed-root-ca` (scripts/embed-apple-root-ca.sh) has downloaded it from Apple and rewritten this file,
// the constant below is empty and POST /attest fails closed (500 server_misconfigured) — no attestation is
// accepted. `npm run deploy` refuses to deploy while it is empty.
//
// SHA-256 fingerprint: (filled in by scripts/embed-apple-root-ca.sh; also record it in README.md)

export const APPLE_APP_ATTESTATION_ROOT_CA_PEM = "";
