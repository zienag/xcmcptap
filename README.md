# Xcode MCP Tap

A macOS service that proxies MCP clients to Xcode through a single
shared `mcpbridge` process, so Xcode's permission dialog is approved
once instead of on every agent session.

## Installation

```sh
brew tap zienag/tap
brew install --cask xcmcptap
```

A DMG is also available from
[Releases](https://github.com/zienag/xcmcptap/releases). The first
launch of the app registers a LaunchAgent that runs the service in the
background, independent of the UI.

## Client configuration

The client binary is installed at `~/.local/bin/xcmcptap`. Settings
can additionally create `/usr/local/bin/xcmcptap` for a machine-wide
path.

Registration commands for CLI agents:

```sh
claude mcp add --transport stdio xcode -- ~/.local/bin/xcmcptap
codex mcp add xcode -- ~/.local/bin/xcmcptap
gemini mcp add xcode ~/.local/bin/xcmcptap
```

Standard MCP server entry for editor agents (Cursor, VS Code, Windsurf):

```json
{ "mcpServers": { "xcode": { "command": "/Users/you/.local/bin/xcmcptap" } } }
```

The Settings pane contains copy-paste snippets for every supported
client.

## Requirements

macOS 26 (Tahoe) or newer. Xcode 26.3 or newer for the bundled
`mcpbridge`.
