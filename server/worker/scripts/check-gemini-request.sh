#!/bin/sh
# Asks for the Gemini key without showing it, then runs check-gemini-request.mjs (the key goes to it on stdin, never on
# a command line). See that file for what it sends and prints.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
key=${GEMINI_API_KEY:-}
if [ -z "$key" ]; then
  printf 'Gemini API key (not shown): ' >&2
  stty -echo 2>/dev/null || true
  IFS= read -r key || true
  stty echo 2>/dev/null || true
  printf '\n' >&2
fi
printf '%s' "$key" | node "$here/check-gemini-request.mjs"
