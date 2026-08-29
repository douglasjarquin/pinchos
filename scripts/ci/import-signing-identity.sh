#!/usr/bin/env bash
#
# Imports the Developer ID Application certificate into a throwaway keychain
# for this CI run only. Used by .github/workflows/release.yml.
#
# Required environment:
#   APPLE_DEVELOPER_ID_CERTIFICATE_P12      base64-encoded .p12 export
#   APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD password protecting that .p12
#
# Writes PINCHOS_SIGNING_KEYCHAIN to $GITHUB_ENV so later steps in the same
# job can find the keychain. Never echoes secret material.
set -euo pipefail

: "${APPLE_DEVELOPER_ID_CERTIFICATE_P12:?APPLE_DEVELOPER_ID_CERTIFICATE_P12 is required}"
: "${APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD:?APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD is required}"
: "${RUNNER_TEMP:?this script expects to run inside GitHub Actions (RUNNER_TEMP unset)}"

KEYCHAIN_PATH="${RUNNER_TEMP}/pinchos-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"
CERT_PATH="${RUNNER_TEMP}/pinchos-developer-id.p12"

cleanup() { rm -f "$CERT_PATH"; }
trap cleanup EXIT

base64 --decode <<<"$APPLE_DEVELOPER_ID_CERTIFICATE_P12" >"$CERT_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERT_PATH" -k "$KEYCHAIN_PATH" -P "$APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD" \
	-T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

EXISTING_KEYCHAINS=()
while IFS= read -r keychain; do
	EXISTING_KEYCHAINS+=("$keychain")
done < <(security list-keychains -d user | sed 's/^ *"//; s/" *$//')
security list-keychains -d user -s "$KEYCHAIN_PATH" "${EXISTING_KEYCHAINS[@]}"

echo "PINCHOS_SIGNING_KEYCHAIN=${KEYCHAIN_PATH}" >>"$GITHUB_ENV"
echo "Imported Developer ID signing identity into a per-run keychain."
