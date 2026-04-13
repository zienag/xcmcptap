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

**Nobody uses XPC for the client-facing side.** All use HTTP or Unix sockets. Our project uses XPC — the most macOS-native approach.

## mcpbridge Technical Details

- **Binary:** `/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge`, signed by Apple (`com.apple.dt.mcpbridge`)
- **Internals:** Uses `BoardServices.framework` (private) to connect to Xcode's tool service (`com.apple.dt.mcpbridge.tool-service`). Not raw XPC — higher-level BoardServices abstraction.
- **Stdin:** Reads via `FileHandle.bytes.lines` → `AsyncStream<String>` → `JSONRPCDecoder.decode(String)`
- **Env vars:** `MCP_XCODE_PID` (optional, which Xcode to connect to), `MCP_XCODE_SESSION_ID` (optional, session UUID)
- **Integer IDs:** mcpbridge may only support integer JSON-RPC IDs, not string UUIDs (XCodeMCPService implements an ID mapper for this)
- **Two authorization layers:**
  1. **Xcode agent dialog** — per-mcpbridge-launch, in-memory only, no persistent "allow"
  2. **macOS TCC Automation** — only for tools that send Apple Events (BuildProject, RunSomeTests, RenderPreview, ExecuteSnippet). Keyed by client binary's code signing identifier. A proper bundle ID (`alfred.xcmcptap`) can persist TCC entries, unlike bare CLI tools.
- **Protocol version:** Must match what mcpbridge expects. Use `"2025-11-25"` for Xcode 26.3.

## Build, Test & Install

```bash
# Xcode project (primary)
xcodegen generate                      # regen after target/build-setting changes in project.yml
xcodebuild -scheme XcodeMCPTap         # Build .app bundle (debug)

# SPM (libraries/tests)
swift build                            # Build all SPM targets
swift build -Xswiftc -warnings-as-errors  # Same, with warnings as errors
swift test                             # Run all SPM tests
swift test --filter UISnapshotTests    # Or filter by target name

# Install & distribute
./install.sh                           # Regenerate project, build release, sign, notarize, install to ~/Applications
./install.sh --dmg                     # Same as above, but package into a .dmg instead of installing
./install.sh --uninstall               # Remove app, LaunchAgent, and symlink
```

**Warnings-as-errors:** Xcode builds enforce this via `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` in `project.yml`. SPM has no clean Package.swift setting for this — pass `-Xswiftc -warnings-as-errors` on the command line.

### Xcode Project

The `.xcodeproj` is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `.xcodeproj` is gitignored, `project.yml` is the source of truth. `install.sh` regenerates it automatically before building. XcodeGen is a build dependency (`brew install xcodegen`).

**Sources use Xcode 16 synchronized folders** (`projectFormat: xcode16_0` + `defaultSourceDirectoryType: syncedFolder`). Adding or removing a `.swift` file inside `App/` does **not** require regenerating — Xcode reads the folder directly. Run `xcodegen generate` only when you change `project.yml` itself (targets, build settings, dependencies, excludes).

### Testing

All tests are SPM targets. Run via `swift test` or the Xcode scheme.

- **`XPCTests`** (`Tests/XPCTests/`) — Service-layer integration tests.
  - **`SubprocessRoundTripTests`** — Verifies subprocess stdio with `scripts/mock-mcpbridge.py` and real mcpbridge. No LaunchAgent needed.
  - **`MCPBridgeHandshakeTests`** — Exercises the raw mcpbridge init handshake outside XPC.
  - **`MCPProxyTests`** — Tests `BridgeProcess` + `MCPRouter` directly (no XPC). Instantiates the classes, points them at `scripts/mock-mcpbridge.py`, and verifies the full MCP message flow: init handshake, tools/list, tools/call, buffering during init. Includes `xcodeListWindowsClaudeCodeStyle` which replays the exact Claude Code wire traffic (field ordering, `_meta.claudecode/toolUseId`, `progressToken`) and pins the real mcpbridge response shape for `XcodeListWindows`.
  - **`XPCTests`** (echo tests) — Require the echo server LaunchAgent to be registered. The first `swift test` run auto-registers it via `launchctl bootstrap`. The service persists across runs (service name: `alfred.xcmcptap.test-echo`).

- **`UISnapshotTests`** (`Tests/UISnapshotTests/`) — SwiftUI snapshot tests against `XcodeMCPTapUI` using [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing). Pattern: host the view in `NSHostingController`, then `assertSnapshot(of: controller, as: .image(size:))`. Suite-level `.snapshots(record: .missing)` auto-records new baselines. Baselines live in `Tests/UISnapshotTests/__Snapshots__/<suite>/<test>.1.png` and are committed.

- **`FeatureTests`** (`Tests/FeatureTests/`) — TCA `TestStore` tests for the UI reducers. Use `TestClock` for time-dependent effects, override `@Dependency` via `withDependencies:`. Time in state is pinned via `AppFeature.State.previewNow` so snapshot and TestStore fixtures share a clock.

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

**Rule: code that can live in SPM lives in SPM.** `Sources/` is 100% SPM — libraries only, no executables, no exclusions. `App/` is Xcode-native: the `.app` bundle's `@main` entry point and the two thin `@main` tool wrappers. Everything else (views, features, dependency clients, installer) lives in the `XcodeMCPTapUI` library so it's importable by tests and previewable from any package consumer.

**SPM libraries** (`Package.swift`, all under `Sources/`):

- **XcodeMCPTapShared** (`Sources/Shared/`) — `MCPTap` (service name constant), `MCPLine` (Codable message wrapper), `RPCMessage`/`RPCId` (JSON-RPC parsing), plus the status protocol types (`StatusRequest/Response`, `ConnectionInfo`, `ServiceHealth`, `ToolInfo`, `StatusEvent`) — all `Equatable` so they can appear in `@ObservableState`. Used by every other target.
- **XcodeMCPTapClient** (`Sources/Client/`) — Client logic: XPC session, stdin reader, stdout writer. Exposes `public enum ClientMain { public static func run() }`.
- **XcodeMCPTapService** (`Sources/Service/`) — Service logic: `BridgeProcess`, `MCPConnection`, `MCPRouter`, `ConnectionRegistry`, `StatusEndpoint`, plus `public enum ServiceMain { public static func run() }`. Imported by tests.
- **XcodeMCPTapUI** (`Sources/UI/`) — SwiftUI + TCA layer. Organized into four folders:
  - `Views/` — `ContentView`, `OverviewView`, `ToolsView`, `ConnectionsView`, `SettingsView`, plus `StatusDot`, `SidebarItem`, `ToolCategory`, `formatUptime(interval:)`.
  - `Features/` — `AppFeature` (root reducer, owns global state + selection + `now`), `ToolsFeature` (search/selection sub-feature), `SettingsFeature` (copy-reset + uninstall-confirm sub-feature with a `Delegate` action that forwards install/uninstall intent to the root).
  - `Dependencies/` — `StatusClient` (wraps `XPCSession` + event stream in an actor, served via `@Dependency(\.statusClient)`), `ServiceInstallerClient` (install/uninstall/path accessors), `PasteboardClient` (NSPasteboard copy). Each exposes `liveValue` and `testValue`.
  - `DesignSystem/` — `Tokens.swift` (`Spacing`, `Radius`, `IconSize`, `SidebarWidth`, `WindowSize`, `SurfaceOpacity`, `BorderWidth` enums) and `Modifiers.swift` (`cardSurface()`, `cardBorder()`). See "UI layout conventions" below.
  - Top-level `ServiceInstaller.swift` (the live implementation backing `ServiceInstallerClient`) and `PreviewState.swift` (`AppFeature.State.previewRunning()` etc.).
- **xpc-test-echo-server** (`Sources/TestEchoServer/`) — Test helper that echoes `MCPLine` messages back with "echo:" prefix.
- **XPCTests** (`Tests/XPCTests/`) — Swift Testing suite: XPC echo tests, Subprocess round-trip tests, MCP proxy tests.
- **UISnapshotTests** (`Tests/UISnapshotTests/`) — Swift Testing suite: SwiftUI snapshot tests over `XcodeMCPTapUI`.
- **FeatureTests** (`Tests/FeatureTests/`) — Swift Testing suite: TCA `TestStore` tests over `AppFeature` / `ToolsFeature` / `SettingsFeature`.

**Xcode targets** (`project.yml`):

- **XcodeMCPTap** (synced folder `App/`, with `xcmcptap`/`xcmcptapd` excluded) — macOS Application target. `App/XcodeMCPTapApp.swift` holds the `@main App` and imports `XcodeMCPTapUI`. Embeds `xcmcptapd` and `xcmcptap` in `Contents/MacOS/` via Copy Files. The excludes are emitted as a `PBXFileSystemSynchronizedBuildFileExceptionSet` so those subdirs belong exclusively to their own tool targets.
- **xcmcptap** (synced folder `App/xcmcptap/`) — Xcode command-line tool target. Single-file `@main` wrapper: `import XcodeMCPTapClient; ClientMain.run()`.
- **xcmcptapd** (synced folder `App/xcmcptapd/`) — Xcode command-line tool target. Single-file `@main` wrapper: `import XcodeMCPTapService; ServiceMain.run()`.

**Why the tool targets are Xcode-native (not SPM executables):** SPM-built executables get `com.apple.security.get-task-allow` injected into their entitlements in Release builds, and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` at the xcodebuild level does not propagate to SPM products. That entitlement fails notarization. Xcode-native tool targets respect the setting cleanly, so `project.yml` sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` at the project level and `OTHER_CODE_SIGN_FLAGS: --timestamp` in the Release config. No post-build re-signing hacks needed.

### Key design details

- **Subprocess I/O:** `BridgeProcess` uses [swift-subprocess](https://github.com/swiftlang/swift-subprocess) (not Foundation.Process). An `AsyncStream<[UInt8]>` bridges the synchronous `write()` calls (from XPC handlers) to the async `StandardInputWriter` inside the `run()` closure. `preferredBufferSize: 1` is required — larger buffers cause DispatchIO to hold back interactive output. `outputSequence.lines()` reads stdout line-by-line (strips newlines).
- **MCP init caching:** `MCPRouter` pre-initializes the bridge (sends `initialize` + `initialized` + `tools/list`), caches the init response, and replays it to each client. Messages arriving before init completes are buffered in `pendingClientMessages`.
- **Single bridge, many clients:** The service creates ONE shared `BridgeProcess` at startup and multiplexes all XPC connections through it.
- **Platform:** macOS 26.0+, Swift 6.2 with strict concurrency. Uses the `XPC` framework module directly (not the old C `xpc_*` API).
- **Entry points use `@main`, never top-level code.** `@main` goes on a type with `static func main()`. Files containing `@main` must not be named `main.swift` — that filename triggers Swift's script mode and forbids `@main`.
- **No blanket Foundation imports.** Use atomic imports (`import struct Foundation.Data`, `import class Foundation.JSONEncoder`). `Darwin.C` provides C stdlib (`fputs`, `stderr`, `pid_t`, `sleep`, `getuid`). `Dispatch` is its own module, not part of Foundation.
- **`Synchronization.Mutex` is non-copyable.** Cannot assign to a local variable or capture by value. Access through `self` when capturing in closures, or capture the owning object.
- **Thread safety:** All mutable shared state is guarded by `Mutex`. Classes use `@unchecked Sendable` when Mutex provides the safety guarantee. Use `nonisolated(unsafe) var` when synchronization is handled externally (e.g., semaphores in tests).
- **TCA effects + strict concurrency:** `@Reducer struct` is not `Sendable`, so capturing `self` inside `.run { send in ... }` fails. Copy each `@Dependency` into a local before returning the effect: `let clock = self.clock; return .run { ... }`. Or make the effect body a `static` helper taking the deps as parameters.
- **Nested action enums need `@CasePathable`:** `TestStore.receive(\.delegate.install)` traverses nested case paths. The outer `Action` gets it from `@Reducer`; inner enums (e.g. `SettingsFeature.Action.Delegate`) must be annotated explicitly.

### UI layout conventions

- **Use design tokens, never raw numbers.** All spacing, radii, opacities, icon sizes, sidebar widths, and border styling come from `Sources/UI/DesignSystem/Tokens.swift`. New views must read from these enums rather than introduce fresh magic numbers. Repeated card chrome uses `.cardSurface(radius:)` / `.cardBorder(radius:)` from `Modifiers.swift`.
- **Tabular layouts use `Grid` + `GridRow`,** not `HStack` with `.frame(width:)` columns. Grid auto-sizes columns to widest content and mirrors correctly under RTL — fixed widths break both. Examples: `ConnectionsView` (whole table) and `SettingsView` paths card.
- **`GridRow` modifier gotcha:** `GridRow` must be a *direct* child of `Grid`. Wrapping it in `.padding`/`.background`/`.onHover`/etc. makes the result a different view type, and `Grid` no longer treats it as a row. Workarounds: use a `@ViewBuilder` function returning `GridRow` (the call-site inlines), apply per-cell padding instead of per-row, or use `Grid`'s own `verticalSpacing:`/`horizontalSpacing:` arguments. State-bearing per-row views (`@State var hovered`) cannot be `GridRow`-typed without losing layout.
- **Truncated text needs `.minimumScaleFactor`.** Anywhere `.lineLimit(1)` guards a label that could be localized, pair it with `.minimumScaleFactor(0.85)` (or lower for large display values) so non-English strings shrink instead of clipping.
- **RTL snapshot variants are required.** Each top-level view in `Tests/UISnapshotTests/` has a `*RTL` test that wraps the view in `.environment(\.layoutDirection, .rightToLeft)`. New views add the same.
