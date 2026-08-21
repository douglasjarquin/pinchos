#!/usr/bin/env bash
#
# Signs a Pinchos.app bundle with the Developer ID Application identity
# imported by scripts/ci/import-signing-identity.sh. Used by
# .github/workflows/release.yml.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_PATH="${1:?usage: scripts/ci/codesign-app.sh <path-to-Pinchos.app>}"

[[ -d "$APP_PATH" ]] || {
	echo "error: $APP_PATH does not exist" >&2
	exit 1
}

SEARCH_KEYCHAIN_ARGS=()
if [[ -n "${PINCHOS_SIGNING_KEYCHAIN:-}" ]]; then
	SEARCH_KEYCHAIN_ARGS=("$PINCHOS_SIGNING_KEYCHAIN")
fi

IDENTITY="$(
	security find-identity -v -p codesigning "${SEARCH_KEYCHAIN_ARGS[@]}" |
		grep -m1 'Developer ID Application:' |
		sed -E 's/^[[:space:]]*[0-9]+\) [0-9A-Fa-f]+ "([^"]+)"$/\1/'
)"

if [[ -z "$IDENTITY" ]]; then
	echo "error: no 'Developer ID Application' signing identity found in the imported certificate" >&2
	exit 1
fi

echo "==> Signing with identity: ${IDENTITY}"

codesign \
	--force \
	--options runtime \
	--timestamp \
	--entitlements "${ROOT_DIR}/Packaging/pinchos.entitlements" \
	--sign "$IDENTITY" \
	"$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH"

if codesign -dv "$APP_PATH" 2>&1 | grep -qi '^Signature=adhoc'; then
	echo "error: bundle signature is ad hoc, not a Developer ID signature" >&2
	exit 1
fi

echo "==> Codesign complete and verified: ${APP_PATH}"
