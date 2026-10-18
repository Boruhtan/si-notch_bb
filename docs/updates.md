[English](updates.md) · [Русский](ru/updates.md) · [简体中文](zh-CN/updates.md)

# Updates

The app reads GitHub Releases at launch and every six hours. Users can disable background checks, select stable or beta, or check manually in **Settings → About**. A new release appears in About and the menu bar menu. Installation requires **Install and Restart**; preferences and agent configurations are preserved.

DMG is the installer. The updater uses a ZIP plus `update.json`. It checks an Ed25519 signature, ZIP size and SHA-256, bundle ID, version, build and code signature. A failed replacement or launch restores the previous bundle. No privileged helper is installed.

Updates use this repository’s public Releases and do not require a GitHub account. Builds use ad hoc signing; Developer ID signing and notarization remain pending.

## Publish a release

1. Update `version` and `build` in `release.json`; use `-beta.1` for a beta.
2. Add release notes in English to `docs/release-VERSION.md`, describing user-visible fixes. Use the same file for GitHub Releases and the update feed. Commit and push the source.
3. Build and prepare assets with the signing key kept outside the repository:

```sh
scripts/test.sh
scripts/build-app.sh release
scripts/verify-release.sh
scripts/build-dmg.sh
python3 scripts/package-release.py \
  --dmg build/si-notch-macos-arm64-VERSION.dmg \
  --notes docs/release-VERSION.md \
  --private-key /secure/path/update-ed25519.pem \
  --output /tmp/si-notch-release-VERSION
scripts/publish-release.sh /tmp/si-notch-release-VERSION docs/release-VERSION.md
```

Replace `VERSION` with the version in `release.json`. Keep the Ed25519 private key backed up securely; the public key is pinned in installed apps. Never commit or upload the private key as a release asset. Beta releases are marked prerelease and do not replace the latest stable release.

[GitHub Actions](../.github/workflows/ci.yml) tests the source, verifies the ZIP and builds the DMG on each push and pull request. Release signing and publication run locally with the maintainer’s key. No GitHub token is shipped in the app.
