#!/usr/bin/env bash
#
# Pinchos installer.
#
#   curl -fsSL https://douglasjarquin.github.io/pinchos/install.sh | bash
#
# Downloads a published GitHub release artifact, verifies its published
# SHA-256 checksum, and installs Pinchos.app only after a real Gatekeeper
# assessment (Developer ID signature plus notarization).
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

for tool in uname sw_vers curl shasum ditto codesign spctl grep pgrep; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found on PATH: $tool"
done

# Release policy (issue #15): macOS 14+ on arm64 only; no Intel or Rosetta build.
[ "$(uname -s)" = "Darwin" ] || fail "Pinchos is a macOS app; this host reports $(uname -s)."
[ "$(uname -m)" = "arm64" ] || fail "Pinchos releases are Apple Silicon (arm64) only; this host reports $(uname -m)."
macos_major="$(sw_vers -productVersion)"
macos_major="${macos_major%%.*}"
case "$macos_major" in
  ''|*[!0-9]*) fail "could not parse macOS version from sw_vers." ;;
esac
[ "$macos_major" -ge 14 ] || fail "Pinchos requires macOS 14 or later; this host reports $(sw_vers -productVersion)."

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
# The sidecar contract (issue #15 pipeline): literal `shasum -a 256 <zip>`
# output, i.e. "<64-hex>  <zip name>", verifiable with `shasum -a 256 -c`.
curl -fsSL -o "$tmp_dir/$artifact.sha256" "$base_url/$artifact.sha256" \
  || fail "checksum file missing at $base_url/$artifact.sha256; refusing to install an unverified artifact."

info "Verifying SHA-256 checksum..."
( cd "$tmp_dir" && shasum -a 256 -c "$artifact.sha256" )

info "Extracting..."
mkdir -p "$tmp_dir/extract"
ditto -x -k "$tmp_dir/$artifact" "$tmp_dir/extract"
app_src="$tmp_dir/extract/$app_name"
[ -d "$app_src" ] || fail "archive did not contain $app_name."

info "Verifying signature and notarization..."
# codesign --verify alone accepts ad hoc signatures ("signed by someone"), so
# assert the Developer ID authority and run a real Gatekeeper assessment;
# anything unsigned, ad hoc, self-signed, or not notarized fails closed here.
codesign --verify --deep --strict "$app_src" \
  || fail "signature verification failed for $app_name; refusing to install a tampered bundle."
# No `grep -q`: it exits on first match and pipefail then reports codesign's
# SIGPIPE as failure. Plain grep reads all input and prints the matched line.
codesign -dvv "$app_src" 2>&1 | grep "Authority=Developer ID Application:" \
  || fail "$app_name is not signed with a Developer ID Application certificate; refusing to install an ad hoc or self-signed artifact."
spctl --assess --type execute -vv "$app_src" \
  || fail "Gatekeeper assessment failed for $app_name (not notarized); refusing to install."

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

# Stage beside the target and swap, so a failed copy never leaves a partial
# or missing install. Same-directory moves are atomic on one volume.
staging="$install_dir/.${app_name}.tmp-$$"
rm -rf "$staging"
ditto "$app_src" "$staging" || fail "could not stage $app_name into $install_dir."
old=""
if [ -d "$target" ]; then
  old="$install_dir/.${app_name}.old-$$"
  mv "$target" "$old" || { rm -rf "$staging"; fail "could not move existing $target aside."; }
fi
if ! mv "$staging" "$target"; then
  [ -z "$old" ] || mv "$old" "$target" 2>/dev/null || true
  fail "could not install $app_name to $target."
fi
[ -z "$old" ] || rm -rf "$old"

# The install-time `spctl` assessment above is what enforces Gatekeeper
# policy on this path: curl does not set com.apple.quarantine, so Gatekeeper
# would not assess this app at first launch on its own.
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
