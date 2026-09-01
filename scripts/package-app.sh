#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="0.1.0"
output_dir="$root_dir/dist"
skip_build=0

usage() {
  echo "Usage: scripts/package-app.sh [--version X.Y.Z] [--output-dir DIR] [--skip-build]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:?--version requires a value}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:?--output-dir requires a value}"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must match X.Y.Z" >&2
  exit 2
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: v0.1.0 packaging is arm64-only" >&2
  exit 1
fi

cd "$root_dir"
if [[ "$skip_build" -eq 0 ]]; then
  swift build -c release
fi

bin_path="$(swift build -c release --show-bin-path)/pinchos"
[[ -x "$bin_path" ]] || { echo "error: release executable not found at $bin_path" >&2; exit 1; }
[[ "$(lipo -archs "$bin_path")" == "arm64" ]] || { echo "error: executable is not arm64-only" >&2; exit 1; }

app_path="$output_dir/Pinchos.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path" "$app_path/Contents/MacOS/pinchos"
chmod 755 "$app_path/Contents/MacOS/pinchos"
[[ -f Packaging/pinchos.icns ]] || { echo "error: app icon not found at Packaging/pinchos.icns" >&2; exit 1; }
cp Packaging/pinchos.icns "$app_path/Contents/Resources/pinchos.icns"
sed "s/__VERSION__/$version/g" Packaging/Info.plist.template > "$app_path/Contents/Info.plist"
plutil -lint "$app_path/Contents/Info.plist" >/dev/null

echo "Packaged unsigned $app_path"
