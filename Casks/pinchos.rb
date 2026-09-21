# Homebrew cask for Pinchos - the tap is this repository itself
# (`brew tap douglasjarquin/pinchos https://github.com/douglasjarquin/pinchos
# && brew install --cask pinchos`, or `brew install --cask
# douglasjarquin/pinchos/pinchos` without tapping first).
#
# HOW TO BUMP THIS FILE FOR A NEW RELEASE (issue #15 owns the signed-release
# pipeline that publishes the artifacts):
#   1. Cut the release tag vX.Y.Z; the release pipeline signs, notarizes, and
#      publishes Pinchos-X.Y.Z-macos-arm64.zip plus its .sha256 sidecar.
#   2. Download the published Pinchos-X.Y.Z-macos-arm64.zip.sha256 (or
#      recompute with `shasum -a 256` on the zip) and copy the 64-character
#      hex digest below.
#   3. Update `version` to X.Y.Z and `sha256` to that digest. `url` is
#      derived from `version` and does not need manual edits.
#   4. `brew audit --cask Casks/pinchos.rb` and `brew style --cask
#      Casks/pinchos.rb`, then a real `brew install --cask Casks/pinchos.rb`
#      smoke install.
#
# version/sha256 below are placeholders until the first signed v0.1.0
# release exists - installing this cask before then fails checksum
# verification by design rather than silently installing an unverified or
# wrong-version artifact.
cask "pinchos" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/douglasjarquin/pinchos/releases/download/v#{version}/Pinchos-#{version}-macos-arm64.zip"
  name "Pinchos"
  desc "Runs shell commands and pins their latest values to the menu bar"
  homepage "https://github.com/douglasjarquin/pinchos"

  # Releases are arm64-only by explicit decision (issue #15): Homebrew
  # refuses this cask on Intel rather than silently installing under Rosetta.
  depends_on arch: :arm64
  depends_on macos: :sonoma

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
