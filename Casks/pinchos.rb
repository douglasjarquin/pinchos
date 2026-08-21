# Homebrew cask for Pinchos - the tap is this repository itself
# (`brew tap douglasjarquin/pinchos && brew install --cask pinchos`, or
# `brew install --cask douglasjarquin/pinchos/pinchos` without tapping first).
#
# HOW TO BUMP THIS FILE FOR A NEW RELEASE (see docs/releasing.md for the full
# release process):
#   1. Cut a release: `git tag vX.Y.Z && git push origin vX.Y.Z`, and let
#      .github/workflows/release.yml sign, notarize, and publish it.
#   2. Download the published `Pinchos-X.Y.Z-macos-arm64.zip.sha256` from
#      that GitHub release (or recompute with `shasum -a 256` on the
#      downloaded zip) and copy the 64-character hex digest below.
#   3. Update `version` to `X.Y.Z` and `sha256` to that digest. `url` is
#      derived from `version` and does not need manual edits.
#   4. `brew audit --cask pinchos.rb` and `brew style --cask pinchos.rb`,
#      then a real `brew install --cask ./Casks/pinchos.rb` smoke install.
#
# version/sha256 below are placeholders until the first signed v1.2.0
# release exists - installing this cask before then will fail its checksum
# verification by design rather than silently installing an unverified or
# wrong-version artifact.
cask "pinchos" do
  version "1.2.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/douglasjarquin/pinchos/releases/download/v#{version}/Pinchos-#{version}-macos-arm64.zip"
  name "Pinchos"
  desc "Native macOS menu-bar app driven by one declarative TOML config file"
  homepage "https://github.com/douglasjarquin/pinchos"

  # v1.2 is arm64-only by explicit decision (see docs/releasing.md): Homebrew
  # refuses this cask on Intel rather than silently installing under Rosetta.
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Pinchos.app"
  binary "#{appdir}/Pinchos.app/Contents/MacOS/pinchos"

  caveats do
    <<~EOS
      Pinchos reads its config from $XDG_CONFIG_HOME/pinchos/pinchos.toml when
      XDG_CONFIG_HOME is set, otherwise from ~/.config/pinchos/pinchos.toml.

      Launch the menu-bar app once via Spotlight, `open -a Pinchos`, or
      Finder, then run `pinchos init` (the `pinchos` CLI is linked onto your
      PATH by this cask) to create the example config if you don't already
      have one.

      To launch Pinchos automatically at login, add it under
      System Settings > General > Login Items.

      Uninstalling this cask removes Pinchos.app only; your config at
      ~/.config/pinchos/pinchos.toml (or $XDG_CONFIG_HOME) is left in place.
    EOS
  end
end
