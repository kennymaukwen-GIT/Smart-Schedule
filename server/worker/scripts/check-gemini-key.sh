#!/bin/sh
# Checks a Gemini API key the way the Worker uses it, without printing the key or putting it on a command line.
#
#   sh scripts/check-gemini-key.sh            The key itself: asks for it (typing is not shown), or reads
#                                             GEMINI_API_KEY. Calls generativelanguage.googleapis.com the way the
#                                             Worker does (x-goog-api-key). If Google refuses it, also tries the other
#                                             ways Google accepts keys, to tell which kind of key it is.
#   sh scripts/check-gemini-key.sh --worker   The whole path app → Worker → Gemini through the development Worker:
#                                             asks for its URL (or WORKER_URL; with or without /v1beta) and its
#                                             SS_DEV_TOKEN (or SS_DEV_TOKEN).
#
# Prints only HTTP statuses, Google's error codes and the first words of the model's reply.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
model=$(sed -n 's/^[[:space:]]*GEMINI_MODEL_ID[[:space:]]*=[[:space:]]*\([^[:space:]/]*\).*/\1/p' \
  "$here/../../../Config/Base.xcconfig" 2>/dev/null | head -n 1)
model=${GEMINI_MODEL_ID:-${model:-gemini-3.8-flash}}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
printf '{"contents":[{"role":"user","parts":[{"text":"Reply with the single word OK."}]}]}' >"$tmp/body.json"

ask_secret() { # $1 prompt; reads a line without echoing it
  printf '%s' "$1" >&2
  stty -echo 2>/dev/null || true
  IFS= read -r value || true
  stty echo 2>/dev/null || true
  printf '\n' >&2
  printf '%s' "$value"
}

# $1 label, $2 URL, $3 header line (secret; given to curl on stdin, never as an argument).
probe() {
  status=$(printf 'header = "%s"\n' "$3" | curl -sS --max-time 60 --config - -o "$tmp/out.json" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data-binary @"$tmp/body.json" "$2" 2>"$tmp/err.txt") || status=000
  printf '%-44s HTTP %s\n' "$1" "$status"
  if [ "$status" = 000 ]; then sed 's/^/  /' "$tmp/err.txt"; return 0; fi
  node -e '
    const fs = require("fs");
    const text = fs.readFileSync(process.argv[1], "utf8");
    try {
      const json = JSON.parse(text);
      if (json.error) {
        const e = typeof json.error === "string" ? { status: json.error } : json.error;
        const reasons = (e.details || []).map((d) => d.reason).filter(Boolean);
        console.log(`  ${[e.status, ...reasons].filter(Boolean).join(" ")} ${String(e.message || "").slice(0, 160)}`);
      } else {
        const parts = json.candidates?.[0]?.content?.parts ?? [];
        console.log(`  reply: ${parts.map((p) => p.text ?? "").join("").trim().slice(0, 60)}`);
      }
    } catch { console.log(`  ${text.slice(0, 160)}`); }
  ' "$tmp/out.json"
}

if [ "${1:-}" = "--worker" ]; then
  url=${WORKER_URL:-}
  if [ -z "$url" ]; then printf 'Development Worker URL (https://…workers.dev, /v1beta optional): ' >&2; IFS= read -r url; fi
  url=$(printf '%s' "$url" | sed 's/\$()//g') # the xcconfig form https:/$()/… works too
  url=${url%/}
  url=${url%/v1beta} # so does the GEMINI_BASE_URL value from Config/Secrets.xcconfig
  token=${SS_DEV_TOKEN:-}
  [ -n "$token" ] || token=$(ask_secret "SS_DEV_TOKEN of that Worker (not shown): ")
  [ -n "$token" ] || { echo "No token given." >&2; exit 1; }
  echo "Model: $model"
  probe "Worker → Gemini (X-Dev-Token)" "$url/v1beta/models/$model:generateContent" "X-Dev-Token: $token"
  exit 0
fi

key=${GEMINI_API_KEY:-}
[ -n "$key" ] || key=$(ask_secret "Gemini API key (not shown): ")
[ -n "$key" ] || { echo "No key given." >&2; exit 1; }
case "$key" in
  AIza*) kind="AIza… (classic API key)" ;;
  AQ.*) kind="AQ.… (Google's newer key format)" ;;
  *) kind="unrecognised prefix" ;;
esac
echo "Key: $kind, ${#key} characters. Model: $model"

probe "Gemini API, x-goog-api-key (the Worker's way)" \
  "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent" "x-goog-api-key: $key"
if [ "$status" = 200 ]; then
  echo "OK: the Worker can use this key as it is."
  exit 0
fi
probe "Gemini API, Authorization: Bearer" \
  "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent" "Authorization: Bearer $key"
probe "Vertex AI (express mode), x-goog-api-key" \
  "https://aiplatform.googleapis.com/v1/publishers/google/models/$model:generateContent" "x-goog-api-key: $key"
echo "The Worker calls the first of these. Send the lines above (they contain no key) to whoever maintains it."
