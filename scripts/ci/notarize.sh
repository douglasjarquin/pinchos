#!/usr/bin/env bash
set -euo pipefail

zip_path="${1:?Usage: scripts/ci/notarize.sh ZIP_PATH}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required}"
: "${APPLE_API_KEY_P8:?APPLE_API_KEY_P8 is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

key_path="$RUNNER_TEMP/pinchos-notary-api-key.p8"
[[ -f "$zip_path" ]] || { echo "error: notarization archive not found" >&2; exit 1; }
cleanup() {
  rm -f "$key_path"
}
trap cleanup EXIT

printf '%s\n' "$APPLE_API_KEY_P8" > "$key_path"
chmod 600 "$key_path"
xcrun notarytool submit "$zip_path" \
  --key "$key_path" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID" \
  --wait
