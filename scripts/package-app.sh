#!/usr/bin/env bash
#
# Builds pinchos via SwiftPM and assembles an *unsigned* Pinchos.app bundle.
#
# This script never codesigns or notarizes anything - it exists so
# contributors (and PR CI) can verify the app-bundle structure, Info.plist
# metadata, and version propagation without needing Apple Developer
# credentials. The signed, notarized, stapled artifact that end users
# actually install is produced by `.github/workflows/release.yml`, which
# takes this script's output and signs/notarizes it before publishing.
#
# Do not distribute this script's output to normal users: an unsigned app
# will be rejected by Gatekeeper on a clean Mac, which is the point - see
# "Non-goals" in README.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.douglasjarquin.pinchos"
MIN_MACOS="14.0"
CONFIGURATION="release"
VERSION="0.0.0"
OUTPUT_DIR="${ROOT_DIR}/dist"
SKIP_BUILD=0

usage() {
	cat <<'EOF'
Usage: scripts/package-app.sh [options]

Options:
  --version <MAJOR.MINOR.PATCH>   Version to embed in Info.plist as both
                                   CFBundleShortVersionString and
                                   CFBundleVersion (default: 0.0.0, i.e. for
                                   local/PR structure smoke tests).
  --configuration <release|debug> SwiftPM build configuration (default: release).
  --output-dir <dir>              Where to write Pinchos.app (default: ./dist).
  --skip-build                    Reuse an already-built binary instead of
                                   running `swift build` again.
  -h, --help                      Show this help.

Produces an UNSIGNED <output-dir>/Pinchos.app. Never publish this as the
normal-user distribution artifact - see .github/workflows/release.yml for
the signed/notarized path.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--version)
		VERSION="${2:?--version requires a value}"
		shift 2
		;;
	--configuration)
		CONFIGURATION="${2:?--configuration requires a value}"
		shift 2
		;;
	--output-dir)
		OUTPUT_DIR="${2:?--output-dir requires a value}"
		shift 2
		;;
	--skip-build)
		SKIP_BUILD=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "error: unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "error: --version must be MAJOR.MINOR.PATCH digits with no leading 'v' (got '$VERSION')" >&2
	exit 2
fi

# v1.2 is arm64-only by explicit decision (see docs/releasing.md): no
# universal2, no silent Rosetta translation of an Intel or universal build.
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" != "arm64" ]]; then
	echo "error: pinchos v1.2 packaging is arm64-only; refusing to package on host architecture '$HOST_ARCH'" >&2
	exit 1
fi

cd "$ROOT_DIR"

if [[ "$SKIP_BUILD" -ne 1 ]]; then
	echo "==> swift build -c ${CONFIGURATION}"
	swift build -c "$CONFIGURATION"
fi

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
BIN_PATH="${BIN_DIR}/pinchos"
if [[ ! -x "$BIN_PATH" ]]; then
	echo "error: built executable not found at $BIN_PATH (build it first, or drop --skip-build)" >&2
	exit 1
fi

BUILT_ARCHS="$(lipo -archs "$BIN_PATH")"
if [[ "$BUILT_ARCHS" != "arm64" ]]; then
	echo "error: built executable architectures are '$BUILT_ARCHS', expected exactly 'arm64'" >&2
	exit 1
fi

APP_DIR="${OUTPUT_DIR}/Pinchos.app"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "$BIN_PATH" "${APP_DIR}/Contents/MacOS/pinchos"
chmod +x "${APP_DIR}/Contents/MacOS/pinchos"

sed \
	-e "s/__BUNDLE_ID__/${BUNDLE_ID}/g" \
	-e "s/__VERSION__/${VERSION}/g" \
	-e "s/__MIN_MACOS__/${MIN_MACOS}/g" \
	"${ROOT_DIR}/Packaging/Info.plist.template" >"${APP_DIR}/Contents/Info.plist"

plutil -lint "${APP_DIR}/Contents/Info.plist" >/dev/null

echo "==> Packaged (unsigned) app bundle: ${APP_DIR}"
echo "${APP_DIR}"
