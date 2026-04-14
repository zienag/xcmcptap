# Xcode MCP Tap

A signed, notarized macOS service that keeps a single `mcpbridge` process
alive and proxies every MCP client connection through it — so Xcode's
"agent wants to use Xcode's tools" permission dialog only appears **once**,
not every time a coding agent starts a session.

## Install

```sh
brew tap zienag/tap
brew install --cask xcmcptap
open -a "Xcode MCP Tap"
```

Launch the app once to register the LaunchAgent. After that, point any
MCP-capable agent at `~/.local/bin/xcmcptap` (or `/usr/local/bin/xcmcptap`
if you enable the system-wide symlink from Settings).

Requires macOS 26 (Tahoe) or newer. The tap is private — you need a
GitHub token with access to `zienag/homebrew-tap`:

```sh
export HOMEBREW_GITHUB_API_TOKEN="$(gh auth token)"
```

Direct DMG download from [Releases](https://github.com/zienag/xcmcptap/releases)
also works.

## Release

Tag and push:

```sh
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

`.github/workflows/release.yml` builds, signs, notarizes, creates a
GitHub Release with the DMG, and updates
[`zienag/homebrew-tap`](https://github.com/zienag/homebrew-tap) with the
new cask version + SHA256.

### Required GitHub Secrets

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERT_P12` | Base64-encoded `.p12` of the Developer ID Application cert |
| `DEVELOPER_ID_CERT_PASSWORD` | Password for the `.p12` |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_ID_PASSWORD` | App-specific password (not iCloud password) |
| `KEYCHAIN_PASSWORD` | Arbitrary password for the runner's temp keychain |
| `TAP_REPO_TOKEN` | GitHub PAT with `contents:write` on `zienag/homebrew-tap` |
