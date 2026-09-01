#!/usr/bin/env bash
set -euo pipefail

app_path="${1:?Usage: scripts/smoke-app-bundle.sh APP_PATH [VERSION]}"
expected_version="${2:-}"
info_plist="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/pinchos"
icon="$app_path/Contents/Resources/pinchos.icns"

[[ -d "$app_path" ]] || { echo "error: app bundle not found" >&2; exit 1; }
[[ -f "$info_plist" ]] || { echo "error: Info.plist not found" >&2; exit 1; }
[[ -x "$executable" ]] || { echo "error: bundled executable not found" >&2; exit 1; }
[[ -f "$icon" ]] || { echo "error: app icon not found" >&2; exit 1; }
plutil -lint "$info_plist" >/dev/null

bundle_id="$(plutil -extract CFBundleIdentifier raw "$info_plist")"
bundle_version="$(plutil -extract CFBundleShortVersionString raw "$info_plist")"
minimum_os="$(plutil -extract LSMinimumSystemVersion raw "$info_plist")"
ui_element="$(plutil -extract LSUIElement raw "$info_plist")"

[[ "$bundle_id" == "com.douglasjarquin.pinchos" ]] || { echo "error: wrong bundle identifier" >&2; exit 1; }
[[ "$minimum_os" == "14.0" ]] || { echo "error: wrong minimum macOS" >&2; exit 1; }
[[ "$ui_element" == "1" || "$ui_element" == "true" ]] || { echo "error: LSUIElement is not enabled" >&2; exit 1; }
[[ "$(lipo -archs "$executable")" == "arm64" ]] || { echo "error: bundled executable is not arm64-only" >&2; exit 1; }
if [[ -n "$expected_version" && "$bundle_version" != "$expected_version" ]]; then
  echo "error: expected version $expected_version, found $bundle_version" >&2
  exit 1
fi

config_path="$($executable config-path)"
[[ -n "$config_path" ]] || { echo "error: bundled CLI did not return a config path" >&2; exit 1; }
echo "Bundle smoke passed: $app_path ($bundle_version, arm64, config $config_path)"
