# Releasing

This documents the v1.2 signed-release pipeline added for [issue #15](https://github.com/douglasjarquin/pinchos/issues/15). It's for maintainers cutting a release and for anyone auditing what the release workflow does with credentials.

## Decisions this pipeline implements

| Decision | Value |
|---|---|
| Tag pattern | `vMAJOR.MINOR.PATCH` (e.g. `v1.2.0`). The tag is the sole version source. |
| Version metadata | `CFBundleShortVersionString` and `CFBundleVersion` are both set to the tag's digits with the leading `v` stripped (`v1.2.0` -> `1.2.0`). |
| Architecture | arm64-only. No universal2, no silent Rosetta translation. `scripts/package-app.sh` and the Homebrew cask both refuse to run/install on a non-arm64 host. |
| Artifact | `Pinchos-<version>-macos-arm64.zip`, containing `Pinchos.app`. |
| Homebrew | A **cask** (`Casks/pinchos.rb`), not a formula. This repository is the tap. |
| Bundle identifier | `com.douglasjarquin.pinchos`. |
| Signing | Developer ID Application (not App Store), notarized via `notarytool` with an App Store Connect API key. |

## Required GitHub Actions secrets

The release workflow (`.github/workflows/release.yml`) **fails closed** on a version tag if any of these are missing - it will not publish an unsigned build as the normal-user artifact. As of this writing, the repository does not have these secrets configured, so pushing a tag today will produce a red release run until they're added.

| Secret | Contents |
|---|---|
| `APPLE_DEVELOPER_ID_CERTIFICATE_P12` | Base64-encoded export of a **Developer ID Application** certificate + private key, as a `.p12` file (`base64 -i Certificate.p12 \| pbcopy`). |
| `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password protecting that `.p12` export. |
| `APPLE_TEAM_ID` | The 10-character Apple Developer Team ID the certificate belongs to. |
| `APPLE_API_KEY_ID` | App Store Connect API key ID for a key with the "Developer" role (used by `notarytool`). |
| `APPLE_API_ISSUER_ID` | App Store Connect API issuer ID for the same key. |
| `APPLE_API_KEY_P8` | The full contents of the key's `.p8` private key file. |

None of these values are invented or present anywhere in this repository; a human with an active Apple Developer Program membership must generate and add them under the repo's Settings > Secrets and variables > Actions.

The workflow never echoes any of these into logs. Certificates are imported into a per-run keychain in `$RUNNER_TEMP` (destroyed with the runner) and API key material is written to a temp file with `chmod 600`, also under `$RUNNER_TEMP`.

## Cutting a release

```sh
git tag v1.2.0
git push origin v1.2.0
```

This triggers `.github/workflows/release.yml`, which:

1. Checks out the exact tagged commit, validates the tag matches `vMAJOR.MINOR.PATCH`, confirms an arm64 runner, and records the macOS/Xcode/Swift/commit/architecture inputs it used.
2. Runs `swift package resolve` and fails if that would change the committed `Package.resolved` (release builds use the locked dependency versions, never a fresh resolution).
3. Runs `swift test` and `swift build -c release`.
4. Packages an unsigned `Pinchos.app` with `scripts/package-app.sh` and runs `scripts/smoke-app-bundle.sh` against it.
5. In a second job: verifies all six signing secrets are present (exits non-zero otherwise), imports the Developer ID certificate, codesigns with Hardened Runtime, zips with `ditto` and submits to `notarytool`, staples the ticket once accepted, re-verifies the signature and re-runs the smoke checks against the now-signed-and-stapled bundle, re-zips the final artifact, generates a `sha256` checksum file, and publishes both to the GitHub release for that tag.

Checksums are generated *after* stapling, so they cover the exact bytes a user downloads - stapling mutates the bundle, so checksums generated any earlier would not match the published artifact.

## Rerunning or re-tagging

Re-running the workflow for a tag whose release already exists is **idempotent** as long as the tag still points at the same commit that created the release: the workflow detects the existing release, confirms `targetCommitish` matches the current commit, and overwrites that release's artifacts (`gh release upload --clobber`).

If a tag is deleted and re-pushed at a **different** commit while a release for that tag name already exists, the workflow refuses to overwrite it and fails with an explicit error naming both commits. Delete the stale GitHub release (and decide whether to also delete/re-push the tag) deliberately before retrying - the pipeline will never silently publish one commit's artifacts under a release that was already associated with a different commit.

## Local, unsigned packaging (no Apple credentials needed)

For structure/metadata smoke testing, or as a contributor without signing credentials:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/package-app.sh --version 1.2.0
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/smoke-app-bundle.sh dist/Pinchos.app 1.2.0
```

This produces `dist/Pinchos.app`, unsigned. `.github/workflows/ci.yml`'s `packaging-smoke` job runs the same two commands on every PR and push, so bundle-structure regressions are caught without needing any Apple credentials in CI. **Never distribute this unsigned bundle to normal users** - it will fail Gatekeeper on a clean Mac by design, and that's the point: the only normal-user artifact is the one `release.yml` signs and notarizes.

## Bumping the Homebrew cask after a release

`Casks/pinchos.rb` pins an exact `version` and `sha256`. After a release publishes:

1. Download `Pinchos-<version>-macos-arm64.zip.sha256` from the new GitHub release (or run `shasum -a 256` on the downloaded zip yourself).
2. Update `version` and `sha256` in `Casks/pinchos.rb` to match.
3. `brew audit --cask Casks/pinchos.rb`, `brew style --cask Casks/pinchos.rb`, then `brew install --cask Casks/pinchos.rb` as a real smoke install.

This repository is the tap itself. Because it isn't named `homebrew-pinchos`, the one-argument `brew tap` shortcut doesn't apply - install with:

```sh
brew tap douglasjarquin/pinchos https://github.com/douglasjarquin/pinchos
brew install --cask pinchos
```

## Known caveat: `pinchos service` vs. `SMAppService`

`pinchos service install/status/uninstall` (issue #17) manages a per-user `launchd` LaunchAgent by absolute executable path, because at the time it shipped Pinchos had no `.app` bundle for `SMAppService` to register. Now that packaging exists, a future change could migrate login-item management to `SMAppService.mainApp` for users running the bundled app (the `doctor` command already reports `SMAppService.mainApp.status` when `Bundle.main` is inside a `.app`). That migration is out of scope here: `pinchos service` continues to work by pointing its LaunchAgent at whatever `--executable` path you give it, including a path inside an installed `Pinchos.app`, but it does not yet get the tighter OS-level integration (Login Items UI, no separate plist) that `SMAppService` would provide for the bundled distribution.
