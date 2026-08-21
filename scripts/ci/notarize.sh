#!/usr/bin/env bash
#
# Submits a zip archive to Apple notarization and waits for a result. Used
# by .github/workflows/release.yml, after codesign-app.sh and before
# `xcrun stapler staple`.
#
# Required environment:
#   APPLE_API_KEY_ID        App Store Connect API key ID
#   APPLE_API_ISSUER_ID     App Store Connect API issuer ID
#   APPLE_API_KEY_P8        contents of the .p8 private key file
set -euo pipefail

ZIP_PATH="${1:?usage: scripts/ci/notarize.sh <path-to-zip>}"

: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required}"
: "${APPLE_API_KEY_P8:?APPLE_API_KEY_P8 is required}"
: "${RUNNER_TEMP:?this script expects to run inside GitHub Actions (RUNNER_TEMP unset)}"

[[ -f "$ZIP_PATH" ]] || {
	echo "error: $ZIP_PATH does not exist" >&2
	exit 1
}

KEY_PATH="${RUNNER_TEMP}/pinchos-notary-api-key.p8"
SUBMIT_LOG="${RUNNER_TEMP}/pinchos-notarytool-submit.json"

cleanup() { rm -f "$KEY_PATH"; }
trap cleanup EXIT

printf '%s\n' "$APPLE_API_KEY_P8" >"$KEY_PATH"
chmod 600 "$KEY_PATH"

echo "==> Submitting ${ZIP_PATH} to Apple notarization (this can take several minutes)..."
if ! xcrun notarytool submit "$ZIP_PATH" \
	--key "$KEY_PATH" \
	--key-id "$APPLE_API_KEY_ID" \
	--issuer "$APPLE_API_ISSUER_ID" \
	--wait \
	--timeout 30m \
	--output-format json >"$SUBMIT_LOG"; then
	echo "error: notarization submission failed or was rejected" >&2
	SUBMISSION_ID="$(plutil -extract id raw "$SUBMIT_LOG" 2>/dev/null || true)"
	if [[ -n "$SUBMISSION_ID" ]]; then
		echo "==> Fetching notarization log for submission ${SUBMISSION_ID}:" >&2
		xcrun notarytool log "$SUBMISSION_ID" \
			--key "$KEY_PATH" \
			--key-id "$APPLE_API_KEY_ID" \
			--issuer "$APPLE_API_ISSUER_ID" || true
	fi
	cat "$SUBMIT_LOG" >&2 || true
	exit 1
fi

cat "$SUBMIT_LOG"
STATUS="$(plutil -extract status raw "$SUBMIT_LOG" 2>/dev/null || true)"
if [[ "$STATUS" != "Accepted" ]]; then
	echo "error: notarization status was '${STATUS}', expected 'Accepted'" >&2
	exit 1
fi

echo "==> Notarization accepted."
