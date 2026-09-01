#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_path="${1:?Usage: scripts/ci/codesign-app.sh APP_PATH}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

keychain_args=()
if [[ -n "${PINCHOS_SIGNING_KEYCHAIN:-}" ]]; then
  keychain_args=("$PINCHOS_SIGNING_KEYCHAIN")
fi

[[ -d "$app_path" ]] || { echo "error: app bundle not found" >&2; exit 1; }
if [[ ! "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "error: APPLE_TEAM_ID must be a 10-character Apple team identifier" >&2
  exit 1
fi
identity="$(security find-identity -v -p codesigning "${keychain_args[@]}" | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | grep -m1 "(${APPLE_TEAM_ID})$" || true)"
[[ -n "$identity" ]] || { echo "error: Developer ID Application identity not found" >&2; exit 1; }

codesign --force --options runtime --timestamp \
  --entitlements "$root_dir/Packaging/pinchos.entitlements" \
  --sign "$identity" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
