#!/usr/bin/env bash
set -euo pipefail

: "${APPLE_DEVELOPER_ID_CERTIFICATE_P12:?APPLE_DEVELOPER_ID_CERTIFICATE_P12 is required}"
: "${APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD:?APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

keychain_path="$RUNNER_TEMP/pinchos-signing.keychain-db"
certificate_path="$RUNNER_TEMP/pinchos-developer-id.p12"
keychain_password="$(openssl rand -base64 32)"

cleanup() {
  rm -f "$certificate_path"
}
trap cleanup EXIT

printf '%s' "$APPLE_DEVELOPER_ID_CERTIFICATE_P12" | base64 --decode > "$certificate_path"
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$certificate_path" -k "$keychain_path" -P "$APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path"

existing_keychains=()
while IFS= read -r keychain; do
  existing_keychains+=("$keychain")
done < <(security list-keychains -d user | sed 's/^ *"//; s/" *$//')
security list-keychains -d user -s "$keychain_path" "${existing_keychains[@]}"

printf 'PINCHOS_SIGNING_KEYCHAIN=%s\n' "$keychain_path" >> "$GITHUB_ENV"
