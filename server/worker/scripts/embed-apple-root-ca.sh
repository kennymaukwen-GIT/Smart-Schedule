#!/bin/sh
# Downloads the Apple App Attestation Root CA from Apple over HTTPS and embeds it in src/apple-root-ca.ts.
#
#   npm run embed-root-ca
#   EXPECTED_SHA256=AA:BB:… npm run embed-root-ca     # also require this fingerprint (recommended)
#   PEM_FILE=apple.pem npm run embed-root-ca           # a copy already downloaded from Apple (e.g. by CI)
#
# CI downloads Apple's file on every run and fails if the embedded certificate differs from it.
#
# Never edit the certificate by hand and never take it from anywhere but Apple.
set -eu

URL="https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT_DIR/src/apple-root-ca.ts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "${PEM_FILE:-}" ]; then
  cp "$PEM_FILE" "$TMP/download.pem"
  ORIGIN="$URL (downloaded by CI, embedded from $(basename "$PEM_FILE"))"
else
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 -o "$TMP/download.pem" "$URL"
  ORIGIN="$URL"
fi

if [ "$(grep -c -- '-----BEGIN CERTIFICATE-----' "$TMP/download.pem")" != "1" ]; then
  echo "error: expected exactly one PEM certificate from $URL" >&2
  exit 1
fi
# Re-encode through OpenSSL: proves it parses and drops anything outside the PEM block.
openssl x509 -in "$TMP/download.pem" -outform PEM -out "$TMP/root.pem"

SUBJECT="$(openssl x509 -in "$TMP/root.pem" -noout -subject)"
ISSUER="$(openssl x509 -in "$TMP/root.pem" -noout -issuer)"
case "$SUBJECT" in
  *"Apple App Attestation Root CA"*) ;;
  *) echo "error: unexpected subject: $SUBJECT" >&2; exit 1 ;;
esac
if [ "${SUBJECT#subject=}" != "${ISSUER#issuer=}" ]; then
  echo "error: not self-signed (issuer: $ISSUER)" >&2
  exit 1
fi
openssl verify -CAfile "$TMP/root.pem" "$TMP/root.pem" >/dev/null

FINGERPRINT="$(openssl x509 -in "$TMP/root.pem" -noout -fingerprint -sha256 | sed 's/^[^=]*=//' | tr 'a-f' 'A-F')"
NOT_AFTER="$(openssl x509 -in "$TMP/root.pem" -noout -enddate | sed 's/^notAfter=//')"
if [ -n "${EXPECTED_SHA256:-}" ] && [ "$(printf '%s' "$EXPECTED_SHA256" | tr 'a-f' 'A-F')" != "$FINGERPRINT" ]; then
  echo "error: fingerprint $FINGERPRINT does not match EXPECTED_SHA256" >&2
  exit 1
fi

{
  echo "// Apple App Attestation Root CA — the only trust anchor for POST /attest."
  echo "//"
  echo "// Source: $ORIGIN"
  echo "// Downloaded: $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/embed-apple-root-ca.sh"
  echo "// ${SUBJECT}"
  echo "// notAfter: ${NOT_AFTER}"
  echo "// SHA-256 fingerprint: ${FINGERPRINT}"
  echo ""
  printf 'export const APPLE_APP_ATTESTATION_ROOT_CA_PEM = `'
  cat "$TMP/root.pem"
  echo '`;'
} > "$OUT"

echo "Embedded $SUBJECT"
echo "SHA-256 fingerprint: $FINGERPRINT"
echo "Compare it with an independent source, then record it in README.md (section \"Apple App Attestation Root CA\")."
