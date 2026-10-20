#!/bin/sh
# Checks the Google Routes API key (「該出發了」) the way the Worker uses it, without printing the key or putting it on a
# command line: asks for it (typing is not shown), or reads GOOGLE_ROUTES_API_KEY.
#
# Makes ONE computeRoutes call: public transport from 台北車站 to 台北 101, the cheapest tier (Compute Routes Essentials,
# inside the 10,000 free calls a month). Prints only the HTTP status, Google's error code and the travel time.
set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
printf '%s' '{"origin":{"address":"台北車站"},"destination":{"address":"台北101"},"travelMode":"TRANSIT","computeAlternativeRoutes":false,"languageCode":"zh-TW","regionCode":"tw"}' >"$tmp/body.json"

key=${GOOGLE_ROUTES_API_KEY:-}
if [ -z "$key" ]; then
  printf 'Google Routes API key (not shown): ' >&2
  stty -echo 2>/dev/null || true
  IFS= read -r key || true
  stty echo 2>/dev/null || true
  printf '\n' >&2
fi
[ -n "$key" ] || { echo "No key given." >&2; exit 1; }
echo "Key: ${#key} characters."

# The key goes to curl on stdin (a config line), never as an argument that `ps` could show.
status=$(printf 'header = "X-Goog-Api-Key: %s"\n' "$key" | curl -sS --max-time 30 --config - -o "$tmp/out.json" -w '%{http_code}' \
  -H 'Content-Type: application/json' -H 'X-Goog-FieldMask: routes.duration,routes.localizedValues' \
  --data-binary @"$tmp/body.json" https://routes.googleapis.com/directions/v2:computeRoutes 2>"$tmp/err.txt") || status=000
echo "Routes API: HTTP $status"
if [ "$status" = 000 ]; then sed 's/^/  /' "$tmp/err.txt"; exit 1; fi
node -e '
  const fs = require("fs");
  const text = fs.readFileSync(process.argv[1], "utf8");
  try {
    const json = JSON.parse(text);
    if (json.error) {
      const reasons = (json.error.details || []).map((d) => d.reason).filter(Boolean);
      console.log(`  ${[json.error.status, ...reasons].filter(Boolean).join(" ")} ${String(json.error.message || "").slice(0, 200)}`);
      console.log("  403 PERMISSION_DENIED: the key is not allowed to use the Routes API (step 3 or 4), or billing is off (step 2).");
    } else if (json.routes?.length) {
      console.log(`  OK: 台北車站 → 台北 101 by public transport, ${json.routes[0].localizedValues?.duration?.text ?? json.routes[0].duration}`);
    } else {
      console.log("  The key works, but Google found no route this time.");
    }
  } catch { console.log(`  ${text.slice(0, 200)}`); }
' "$tmp/out.json"
