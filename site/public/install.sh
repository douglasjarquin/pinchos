#!/usr/bin/env bash
#
# Pinchos installer.
#
#   curl -fsSL https://douglasjarquin.github.io/pinchos/install.sh | bash
#
# Downloads a published GitHub release artifact, verifies its published
# SHA-256 checksum and Developer ID signature, and installs Pinchos.app.
#
# Environment:
#   PINCHOS_VERSION      Version to install (default: latest release), e.g. 0.1.0
#   PINCHOS_INSTALL_DIR  Install location (default: /Applications when writable,
#                        otherwise ~/Applications)
#   PINCHOS_BASE_URL     Artifact base URL override for testing/mirrors
#                        (default: the GitHub release download URL)

set -euo pipefail

repo="douglasjarquin/pinchos"
app_name="Pinchos.app"

info() { printf '%s\n' "$*"; }
fail() { printf 'install: error: %s\n' "$*" >&2; exit 1; }

# Release policy (issue #15): macOS arm64 only, no Intel or Rosetta build.
[ "$(uname -s)" = "Darwin" ] || fail "Pinchos is a macOS app; this host reports $(uname -s)."
[ "$(uname -m)" = "arm64" ] || fail "Pinchos releases are Apple Silicon (arm64) only; this host reports $(uname -m)."

for tool in curl shasum ditto codesign; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found on PATH: $tool"
done

version="${PINCHOS_VERSION:-}"
if [ -z "$version" ]; then
  resolved="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest" || true)"
  case "$resolved" in
    */releases/tag/v*) version="${resolved##*/tag/v}" ;;
    *) fail "no published release found for $repo. The first release is v0.1.0 (issue #15); until then build from source per the README." ;;
  esac
fi
version="${version#v}"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "invalid version '$version' (expected X.Y.Z)."

artifact="Pinchos-${version}-macos-arm64.zip"
base_url="${PINCHOS_BASE_URL:-https://github.com/$repo/releases/download/v${version}}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pinchos-install.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

info "Downloading Pinchos v$version ($artifact)..."
curl -fL --progress-bar -o "$tmp_dir/$artifact" "$base_url/$artifact" \
  || fail "download failed: $base_url/$artifact (release may not exist yet)"
curl -fsSL -o "$tmp_dir/$artifact.sha256" "$base_url/$artifact.sha256" \
  || fail "checksum file missing at $base_url/$artifact.sha256; refusing to install an unverified artifact."

info "Verifying SHA-256 checksum..."
( cd "$tmp_dir" && shasum -a 256 -c "$artifact.sha256" )

info "Extracting..."
mkdir -p "$tmp_dir/extract"
ditto -x -k "$tmp_dir/$artifact" "$tmp_dir/extract"
[ -d "$tmp_dir/extract/$app_name" ] || fail "archive did not contain $app_name."

# Releases are Developer ID signed and notarized; fail closed on anything else
# rather than installing unsigned code that presents as a release.
codesign --verify --deep --strict "$tmp_dir/extract/$app_name" \
  || fail "signature verification failed for $app_name; refusing to install an unsigned or tampered bundle."

if [ -n "${PINCHOS_INSTALL_DIR:-}" ]; then
  install_dir="$PINCHOS_INSTALL_DIR"
elif [ -w /Applications ]; then
  install_dir="/Applications"
else
  install_dir="$HOME/Applications"
fi
mkdir -p "$install_dir" || fail "cannot create install directory $install_dir."
target="$install_dir/$app_name"
[ -w "$install_dir" ] || fail "install directory is not writable: $install_dir (set PINCHOS_INSTALL_DIR)."

if [ -d "$target" ]; then
  rm -rf "$target" || fail "could not replace existing $target."
fi
ditto "$tmp_dir/extract/$app_name" "$target" || fail "could not install to $target."

# The quarantine attribute is kept deliberately: the published app is
# notarized, so Gatekeeper accepts it on first launch. Removing quarantine
# would skip that check for no benefit.
cli="$target/Contents/MacOS/pinchos"
config_path="$("$cli" config-path)" || fail "installed app failed its CLI smoke check."

info ""
info "Installed Pinchos v$version to $target"
if pgrep -f "$app_name/Contents/MacOS/pinchos" >/dev/null 2>&1; then
  info "Pinchos is currently running; quit and relaunch it to use v$version."
fi
info ""
info "Next steps:"
info "  open -a Pinchos"
info "  $cli init       # write the example config if none exists"
info "  $cli doctor     # check config and command prerequisites"
info ""
info "Config: $config_path"
