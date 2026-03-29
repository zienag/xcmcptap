# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build, Test & Install

```bash
# Xcode project (primary)
xcodebuild -scheme XcodeMCPTap      # Build .app bundle (debug)
xcodebuild -scheme XcodeMCPTap -configuration Release  # Release build

# SPM (still works for libraries/tests)
swift build                            # Build all SPM targets
swift test                             # Run XPC integration tests

# Install & distribute
./install.sh                           # Build release, sign, notarize, install to ~/Applications
./install.sh --dmg                     # Build release, sign, notarize, create .dmg
./install.sh --uninstall               # Remove app, LaunchAgent, and symlink
NOTARIZE=false ./install.sh            # Skip notarization (local dev)
```

### Xcode Project

The `.xcodeproj` is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen). To regenerate after changing targets or build settings:

```bash
brew install xcodegen    # one-time
xcodegen generate        # regenerate .xcodeproj from project.yml
```

The `.xcodeproj` is gitignored — `project.yml` is the source of truth. `install.sh` regenerates it automatically before building. XcodeGen is a build dependency (`brew install xcodegen`).

### Testing

Tests require the echo server LaunchAgent to be registered. The first `swift test` run auto-registers it via `launchctl bootstrap`. The service persists across runs (service name: `dev.multivibe.xcmcptap.test-echo`).

**XPC session lifecycle:** `XPCSession` must be cancelled via `session.cancel(reason:)` before deallocation — otherwise it crashes with `_xpc_api_misuse`. Always use `defer { session.cancel(reason:) }`.

## Architecture

Xcode MCP Tap is an XPC-based proxy that connects coding agents to Xcode's native `mcpbridge` tool, packaged as a self-installing macOS .app bundle with menu bar UI.

**Communication chain:**

```
Agent ←stdio→ xcmcptap ←XPC→ xcmcptapd ←stdin/stdout→ /usr/bin/xcrun mcpbridge
```

### Self-registration

The app (`App/`) handles installation; the service binary runs as a plain XPC listener:
- **Launch app** (double-click .app) — `ServiceInstaller.install()` registers LaunchAgent, creates `~/.local/bin/xcmcptap` symlink
- **Service** (launched by launchd) — `xcmcptapd` starts XPC listener, runs as persistent service
- **Uninstall** — `ServiceInstaller.uninstall()` removes LaunchAgent plist, symlink, boots out service

### Targets

Defined in both `project.yml` (Xcode project) and `Package.swift` (SPM):

- **XcodeMCPTapShared** (`Sources/Shared/`) — `MCPTap` (service name constant) and `MCPLine` (Codable message wrapper). Static library, all other targets depend on it.
- **XcodeMCPTap** (`App/`) — macOS Application target with menu bar UI. Uses `ServiceInstaller` for install/uninstall, `StatusViewModel` for monitoring. Embeds `xcmcptapd` and `xcmcptap` in `Contents/MacOS/` via Copy Files build phase.
- **xcmcptapd** (`Sources/Service/`) — XPC listener daemon. For each XPC connection, spawns a `BridgeProcess` wrapping `/usr/bin/xcrun mcpbridge`. Routes messages via `MCPRouter`.
- **xcmcptap** (`Sources/Client/`) — Command-line tool bundled in the .app. Reads stdin → sends as XPC messages. Receives XPC messages → prints to stdout.
- **xpc-test-echo-server** (`Sources/TestEchoServer/`) — Test helper that echoes `MCPLine` messages back with "echo:" prefix.
- **XPCTests** (`Tests/XPCTests/`) — XPC integration tests using Swift Testing. Tests find the echo server binary via `swift build --show-bin-path` relative to `#filePath`.

### Key design details

- `BridgeProcess` uses `AsyncStream` and structured concurrency for stdin writes.
- Stdout from the bridge is read via `Subprocess`'s `outputSequence.lines()` in an async task group.
- The service creates one `BridgeProcess` per XPC connection and terminates it on cancellation.
- `MCPRouter` pre-initializes the bridge, caches the init response, and replays it to each client.
- `install.sh` builds via `xcodebuild`, signs with Developer ID, notarizes, and optionally creates a `.dmg`.
- Requires macOS 26.0+ (Swift 6.2, uses Foundation `XPC` module directly).
