#!/usr/bin/env bash
#
# Focused structure/metadata smoke checks for a Pinchos.app bundle produced
# by scripts/package-app.sh (unsigned) or the release workflow (signed).
# Exercises the same Info.plist keys and layout the acceptance criteria in
# GitHub issue #15 require, plus one real invocation of the bundled binary's
# CLI entry point.
set -euo pipefail

APP_PATH="${1:?usage: scripts/smoke-app-bundle.sh <path-to-Pinchos.app> [expected-version]}"
EXPECTED_VERSION="${2:-}"

fail() {
	echo "SMOKE FAIL: $1" >&2
	exit 1
}
pass() {
	echo "SMOKE OK:   $1"
}

[[ -d "$APP_PATH" ]] || fail "bundle not found at $APP_PATH"

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "missing $INFO_PLIST"
plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist failed plutil -lint"
pass "Info.plist is well-formed"

EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw "$INFO_PLIST")"
[[ "$EXECUTABLE_NAME" == "pinchos" ]] || fail "CFBundleExecutable is '$EXECUTABLE_NAME', expected 'pinchos'"
pass "CFBundleExecutable is pinchos"

EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
[[ -f "$EXECUTABLE_PATH" ]] || fail "executable missing at $EXECUTABLE_PATH"
[[ -x "$EXECUTABLE_PATH" ]] || fail "executable at $EXECUTABLE_PATH is not marked executable"
pass "executable present at Contents/MacOS/${EXECUTABLE_NAME}"

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")"
[[ "$BUNDLE_ID" == "com.douglasjarquin.pinchos" ]] || fail "CFBundleIdentifier is '$BUNDLE_ID', expected com.douglasjarquin.pinchos"
pass "CFBundleIdentifier is com.douglasjarquin.pinchos"

MIN_OS="$(plutil -extract LSMinimumSystemVersion raw "$INFO_PLIST")"
[[ "$MIN_OS" == "14.0" ]] || fail "LSMinimumSystemVersion is '$MIN_OS', expected 14.0"
pass "LSMinimumSystemVersion is 14.0"

IS_ACCESSORY="$(plutil -extract LSUIElement raw "$INFO_PLIST" 2>/dev/null || echo "false")"
[[ "$IS_ACCESSORY" == "1" || "$IS_ACCESSORY" == "true" ]] || fail "LSUIElement is not enabled; app would show a Dock icon"
pass "LSUIElement marks this an accessory app (no Dock icon)"

SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
BUNDLE_VERSION="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
[[ "$SHORT_VERSION" == "$BUNDLE_VERSION" ]] || fail "CFBundleShortVersionString ($SHORT_VERSION) and CFBundleVersion ($BUNDLE_VERSION) disagree"
pass "CFBundleShortVersionString and CFBundleVersion agree (${SHORT_VERSION})"

if [[ "$SHORT_VERSION" =~ ^v ]]; then
	fail "version '$SHORT_VERSION' retains a leading 'v'; tag digits should be stripped"
fi
pass "version has no leading 'v' (${SHORT_VERSION})"

if [[ -n "$EXPECTED_VERSION" ]]; then
	[[ "$SHORT_VERSION" == "$EXPECTED_VERSION" ]] || fail "version is '$SHORT_VERSION', expected '$EXPECTED_VERSION'"
	pass "version matches expected ${EXPECTED_VERSION}"
fi

ARCHS="$(lipo -archs "$EXECUTABLE_PATH")"
[[ "$ARCHS" == "arm64" ]] || fail "executable architectures are '$ARCHS', expected exactly 'arm64' (no universal/Rosetta fallback)"
pass "executable is arm64-only"

CLI_OUTPUT="$("$EXECUTABLE_PATH" config-path 2>&1)" || fail "running '${EXECUTABLE_PATH} config-path' failed"
[[ -n "$CLI_OUTPUT" ]] || fail "'config-path' produced no output"
pass "CLI entry point runs inside the bundle (config-path -> ${CLI_OUTPUT})"

echo "All bundle smoke checks passed for ${APP_PATH}"
