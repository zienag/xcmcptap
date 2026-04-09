# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## The Problem We're Solving

Every time a coding agent (Claude Code, Cursor, Codex, etc.) starts an MCP session, it spawns a new `xcrun mcpbridge` process. Each new mcpbridge process triggers **Xcode's permission dialog** ("The agent wants to use Xcode's tools"). This dialog appears per-process-launch and the permission is only held in-memory for that Xcode process lifetime — there's no "permanently allow" option.

**The solution:** A signed, notarized persistent service that connects to mcpbridge **once** (one permission dialog), then proxies all subsequent agent connections through that single mcpbridge instance. No more repeated dialogs.

## Existing Solutions (Prior Art)

Several projects on GitHub solve this same problem. Key reference implementations:

| Project | Client transport | mcpbridge I/O | Notes |
|---|---|---|---|
| [XcodeMCPKit](https://github.com/lynnswap/XcodeMCPKit) | HTTP Streamable (:8765) + stdio adapter | Foundation Process + DispatchSourceRead | Most mature. Init caching. Auto-approver via Accessibility API. Reports periodic mcpbridge hangs. |
| [XCodeMCPService](https://github.com/ljh740/XCodeMCPService) | HTTP Streamable (NWListener) | Foundation Process + POSIX `read()` on dedicated thread | ID mapper (mcpbridge may only support integer IDs). Exponential backoff restart. |
| [xcodecli](https://github.com/oozoofrog/xcodecli) | Unix domain socket | Foundation Process + Pipe + signal forwarding | Go + Swift. Session pool keyed by {XcodePID, SessionID, DeveloperDir}. |
| [xcode-mcp-manager](https://github.com/ndrblinov/xcode-mcp-manager) | stdio (is the MCP server) | Node.js spawn | TypeScript. AppleScript auto-approver. State machine with health checks. |

**Nobody uses XPC for the client-facing side.** All use HTTP or Unix sockets. Our project uses XPC, which is the most macOS-native approach but has proven problematic for subprocess management.

## mcpbridge Technical Details

- **Binary:** `/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge`, signed by Apple (`com.apple.dt.mcpbridge`)
- **Internals:** Uses `BoardServices.framework` (private) to connect to Xcode's tool service (`com.apple.dt.mcpbridge.tool-service`). Not raw XPC — higher-level BoardServices abstraction.
- **Stdin:** Reads via `FileHandle.bytes.lines` → `AsyncStream<String>` → `JSONRPCDecoder.decode(String)`
- **Env vars:** `MCP_XCODE_PID` (optional, which Xcode to connect to), `MCP_XCODE_SESSION_ID` (optional, session UUID)
- **Integer IDs:** mcpbridge may only support integer JSON-RPC IDs, not string UUIDs (XCodeMCPService implements an ID mapper for this)
- **Two authorization layers:**
  1. **Xcode agent dialog** — per-mcpbridge-launch, in-memory only, no persistent "allow"
  2. **macOS TCC Automation** — only for tools that send Apple Events (BuildProject, RunSomeTests, RenderPreview, ExecuteSnippet). Keyed by client binary's code signing identifier. A proper bundle ID (`dev.multivibe.xcmcptap`) can persist TCC entries, unlike bare CLI tools.
- **Protocol version:** Must match what mcpbridge expects. Use `"2025-11-25"` for Xcode 26.3.

## Build, Test & Install

```bash
# Xcode project (primary — run xcodegen first)
xcodegen generate                      # .xcodeproj is gitignored, must regenerate
xcodebuild -scheme XcodeMCPTap         # Build .app bundle (debug)

# SPM (libraries/tests)
swift build                            # Build all SPM targets
swift build -Xswiftc -warnings-as-errors  # Same, with warnings as errors
swift test                             # Run XPC integration tests

# Install & distribute
./install.sh                           # Build release, sign, notarize, install to ~/Applications
./install.sh --dmg                     # Build release, sign, notarize, create .dmg
./install.sh --uninstall               # Remove app, LaunchAgent, and symlink
NOTARIZE=false ./install.sh            # Skip notarization (local dev)
```

**Warnings-as-errors:** Xcode builds enforce this via `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` in `project.yml`. SPM has no clean Package.swift setting for this — pass `-Xswiftc -warnings-as-errors` on the command line.

### Xcode Project

The `.xcodeproj` is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen). To regenerate after changing targets or build settings:

```bash
brew install xcodegen    # one-time
xcodegen generate        # regenerate .xcodeproj from project.yml
```

The `.xcodeproj` is gitignored — `project.yml` is the source of truth. `install.sh` regenerates it automatically before building. XcodeGen is a build dependency (`brew install xcodegen`).

### Testing

There are two test suites:

- **`SubprocessRoundTripTests`** — Verifies subprocess stdio with `fake-mcp-server.py` and real mcpbridge. No LaunchAgent needed.
- **`MCPProxyTests`** — Tests `BridgeProcess` + `MCPRouter` directly (no XPC). Instantiates the classes, points them at `fake-mcp-server.py`, and verifies the full MCP message flow: init handshake, tools/list, tools/call, buffering during init.

The **XPC echo tests** (`XPCTests`) require the echo server LaunchAgent to be registered. The first `swift test` run auto-registers it via `launchctl bootstrap`. The service persists across runs (service name: `dev.multivibe.xcmcptap.test-echo`).

**XPC session lifecycle:** `XPCSession` must be cancelled via `session.cancel(reason:)` before deallocation — otherwise it crashes with `_xpc_api_misuse`. Always use `defer { session.cancel(reason:) }`.

## Architecture

Xcode MCP Tap is a signed, notarized macOS .app that keeps a single `mcpbridge` process alive and proxies MCP connections through it — so the Xcode permission dialog only appears once.

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

- **XcodeMCPTapShared** (`Sources/Shared/`) — `MCPTap` (service name constant), `MCPLine` (Codable message wrapper), `RPCMessage`/`RPCId` (JSON-RPC parsing). Static library, all other targets depend on it.
- **XcodeMCPTapServiceCore** (`Sources/ServiceCore/`) — Reusable service logic: `BridgeProcess`, `MCPRouter`, `ConnectionRegistry`, `StatusEndpoint`. Library target used by both `xcmcptapd` and tests.
- **XcodeMCPTap** (`App/`) — macOS Application target with menu bar UI. Uses `ServiceInstaller` for install/uninstall, `StatusViewModel` for monitoring. Embeds `xcmcptapd` and `xcmcptap` in `Contents/MacOS/` via Copy Files build phase.
- **xcmcptapd** (`Sources/Service/`) — XPC listener daemon entry point. Imports `XcodeMCPTapServiceCore`. Spawns a single shared `BridgeProcess` wrapping `/usr/bin/xcrun mcpbridge`. Routes all client messages via `MCPRouter`.
- **xcmcptap** (`Sources/Client/`) — Command-line tool bundled in the .app. Reads stdin → sends as XPC messages. Receives XPC messages → prints to stdout.
- **xpc-test-echo-server** (`Sources/TestEchoServer/`) — Test helper that echoes `MCPLine` messages back with "echo:" prefix.
- **XPCTests** (`Tests/XPCTests/`) — Integration tests using Swift Testing. Includes XPC echo tests, Subprocess round-trip tests, and MCP proxy tests.

### Key design details

- **Subprocess I/O:** `BridgeProcess` uses [swift-subprocess](https://github.com/swiftlang/swift-subprocess) (not Foundation.Process). An `AsyncStream<[UInt8]>` bridges the synchronous `write()` calls (from XPC handlers) to the async `StandardInputWriter` inside the `run()` closure. `preferredBufferSize: 1` is required — larger buffers cause DispatchIO to hold back interactive output. `outputSequence.lines()` reads stdout line-by-line (strips newlines).
- **MCP init caching:** `MCPRouter` pre-initializes the bridge (sends `initialize` + `initialized` + `tools/list`), caches the init response, and replays it to each client. Messages arriving before init completes are buffered in `pendingClientMessages`.
- **Single bridge, many clients:** The service creates ONE shared `BridgeProcess` at startup and multiplexes all XPC connections through it.
- **Build & distribute:** `install.sh` builds via `xcodebuild`, signs with Developer ID, notarizes, and optionally creates a `.dmg`.
- **Platform:** macOS 26.0+, Swift 6.2 with strict concurrency. Uses the `XPC` framework module directly (not the old C `xpc_*` API).
- **No blanket Foundation imports.** Use atomic imports (`import struct Foundation.Data`, `import class Foundation.JSONEncoder`). `Darwin.C` provides C stdlib (`fputs`, `stderr`, `pid_t`, `sleep`, `getuid`). `Dispatch` is its own module, not part of Foundation.
- **`Synchronization.Mutex` is non-copyable.** Cannot assign to a local variable or capture by value. Access through `self` when capturing in closures, or capture the owning object.
- **Thread safety:** All mutable shared state is guarded by `Mutex`. Classes use `@unchecked Sendable` when Mutex provides the safety guarantee. Use `nonisolated(unsafe) var` when synchronization is handled externally (e.g., semaphores in tests).

## Current Blocker: mcpbridge from xcmcptapd

mcpbridge fails with `DecodeError Code=1` ("could not parse raw message") when spawned from `xcmcptapd` with concurrent I/O. This happens with Foundation.Process, raw posix_spawn, and swift-subprocess — the subprocess library doesn't matter.

**What works:** mcpbridge from terminal, from `launchctl submit`, from the test runner, from xcmcptapd with synchronous single-threaded I/O (unusable for a real service).

**What fails:** mcpbridge from xcmcptapd with ANY concurrent stdout reader. The error correlates with our write arriving at mcpbridge. The data is valid JSON (verified with `xxd` via `tee` wrapper). Adding a stdout read task — even on a completely different fd — triggers the failure.

All existing proxy projects (XcodeMCPKit, XCodeMCPService, xcodecli) spawn mcpbridge from their daemons using Foundation.Process + Pipe. Their code is structurally similar. Need to investigate what they do differently — likely related to using HTTP/NWListener instead of XPC, or differences in launchd service configuration.
