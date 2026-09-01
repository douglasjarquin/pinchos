# Releasing Pinchos

The v0.1.0 release is arm64-only and uses the tag format `vX.Y.Z`.

The release workflow runs Swift tests, builds the release executable, assembles an unsigned app bundle, and smoke-tests its bundle metadata before any signing credentials are used.

The signing job fails closed unless all of these repository secrets are present:

- `APPLE_DEVELOPER_ID_CERTIFICATE_P12`
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_TEAM_ID`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_KEY_P8`

The certificate is imported into an ephemeral runner keychain.

The API key is written to a temporary file and removed on both success and failure.

The signed artifact is stapled, assessed with `spctl`, verified with `codesign`, zipped as `Pinchos-X.Y.Z-macos-arm64.zip`, and published with a SHA-256 checksum.

The Homebrew cask must use the exact version and checksum from that accepted GitHub release artifact.

To create a release, push a version tag after the required Apple credentials and release authority are configured:

```sh
git tag v0.1.0
git push origin v0.1.0
```
