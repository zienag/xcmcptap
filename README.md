# Xcode MCP Tap

A macOS service that proxies MCP clients to Xcode through a single
shared `mcpbridge` process, so Xcode's permission dialog is approved
once instead of on every agent session.

## Installation

```sh
brew tap zienag/tap
brew install --cask xcmcptap
```

Brew copies the .app to `/Applications`, links `xcmcptap` into
`$HOMEBREW_PREFIX/bin` (so it's on your PATH), and registers the
LaunchAgent — no clicks needed. After that, configure your MCP client of
choice:

```sh
claude mcp add --transport stdio xcode -- xcmcptap
codex mcp add xcode -- xcmcptap
gemini mcp add xcode xcmcptap
code --add-mcp '{"name":"xcode","command":"xcmcptap"}'
```

For Cursor / Windsurf, paste this into the editor's MCP config:

```json
{ "mcpServers": { "xcode": { "command": "xcmcptap" } } }
```

A DMG is also available from
[Releases](https://github.com/zienag/xcmcptap/releases) for installs
without Homebrew. Run `Xcode MCP Tap.app/Contents/MacOS/xcmcptap install`
to register the agent, or open the app and use the Settings pane.

The Settings pane contains copy-paste snippets for every supported
client and a one-click button to put `xcmcptap` on `/usr/local/bin` for
non-brew installs.

## Why this one

- Signed and notarized native macOS app with a UI to inspect status.
- Uses XPC instead of an HTTP server — faster than localhost TCP, and no port is occupied.
- Lightweight Swift daemon — no Node, no Electron, no embedded HTTP stack.

## Requirements

macOS 26 (Tahoe) or newer. Xcode 26.3 or newer for the bundled
`mcpbridge`.
