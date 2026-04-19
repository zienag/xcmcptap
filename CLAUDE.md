# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow: TDD Is Mandatory

**This project is developed test-first.** Every behavioral change (bug fix, new feature, edge-case handling) starts with a failing test, then the minimal code change that turns it green. This is non-negotiable.

- **Never write production code before writing a failing test for the behavior you want.**
- Write the test, run it, confirm it fails for the right reason, then implement.
- "Design documents" and prose planning are not a substitute for a failing test. If you find yourself talking about how state should transition without a `@Test` pinning that transition, you're doing it wrong.
- Applies equally to bug fixes: reproduce the bug as a failing test first, then fix the code.
- Applies equally to refactors of behavior-bearing code: there must be a test that would catch a regression before the refactor is made.

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
scripts/uninstall.sh                   # Remove app, LaunchAgent, helper daemon, ~/.local/bin + /usr/local/bin symlinks
```

**Warnings-as-errors:** Xcode builds enforce this via `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` in `project.yml`. SPM has no clean Package.swift setting for this — pass `-Xswiftc -warnings-as-errors` on the command line.

### Xcode Project

The `.xcodeproj` is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `.xcodeproj` is gitignored, `project.yml` is the source of truth. `install.sh` regenerates it automatically before building. XcodeGen is a build dependency (`brew install xcodegen`).

**Sources use Xcode 16 synchronized folders** (`projectFormat: xcode16_0` + `defaultSourceDirectoryType: syncedFolder`). Adding or removing a `.swift` file inside `App/` does **not** require regenerating — Xcode reads the folder directly. Run `xcodegen generate` only when you change `project.yml` itself (targets, build settings, dependencies, excludes).

### Testing

Most tests are SPM targets run via `swift test`. The XCUITest bundle (`XcodeMCPTapUITests`) is an Xcode target — run it through `xcodebuild ... test` against the XcodeMCPTap scheme.

- **`XPCTests`** (`Tests/XPCTests/`) — Service-layer integration tests.
  - **`MCPBridgeHandshakeTests`** — Exercises the raw mcpbridge init handshake outside XPC against the mock.
  - **`MCPProxyTests`** — Tests `BridgeProcess` + `MCPRouter` directly (no XPC). Instantiates the classes, points them at `scripts/mock-mcpbridge.py`, and verifies the full MCP message flow: init handshake, tools/list, tools/call, buffering during init. Includes `xcodeListWindowsClaudeCodeStyle` which replays the exact Claude Code wire traffic (field ordering, `_meta.claudecode/toolUseId`, `progressToken`) and pins the real mcpbridge response shape for `XcodeListWindows`.
  - **`BridgeFailureTests`** — Pins the router's behavior when mcpbridge is broken. Drives `scripts/mock-mcpbridge.py --fail {at-startup,after-init}` to simulate "Xcode not running" (immediate crash before init handshake) and mid-session crash. Asserts every client request receives a JSON-RPC `-32603` error envelope carrying the real stderr reason, notifications are dropped silently, in-flight and pending queues both drain with errors. Regression guard for the silent-hang bug where a dead bridge left clients waiting forever.
  - **`XPCTests`** (echo tests) — Require the echo server LaunchAgent to be registered. The first `swift test` run auto-registers it via `launchctl bootstrap`. The service persists across runs (service name: `alfred.xcmcptap.test-echo`).
  - **`SymlinkOperationsTests` / `HelperHandlerTests`** — Pure unit tests for the privileged helper's file ops and request dispatch, exercised against `$TMPDIR` destinations. No XPC, no launchd.
  - **`HelperProtocolTests`** — Codable round-trip for `HelperRequest` / `HelperResponse`.
  - **`HelperEndToEndTests`** — Bootstraps the same `xcmcptap-helper` SPM executable as a user-level LaunchAgent (service name `alfred.xcmcptap.test-helper`, env `HELPER_MACH_SERVICE` + `HELPER_DESTINATION` + `HELPER_ALLOW_ANY_PEER=1`), then drives the full XPC flow. Always re-bootstraps so plist env stays in sync with the test. Proves production binary works without needing root or a signed daemon registration.

- **`UISnapshotTests`** (`Tests/UISnapshotTests/`) — SwiftUI snapshot tests against `XcodeMCPTapUI` using [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing). Pattern: host the view in `NSHostingController`, then `assertSnapshot(of: controller, as: .image(size:))`. No `.snapshots(record:)` trait on the suites — the library default (`.missing`) auto-records new baselines on first run. To re-record after copy/layout changes, use `SNAPSHOT_TESTING_RECORD=failed swift test --filter UISnapshotTests` — it only rewrites snapshots whose baseline actually differs, so `git status` shows exactly what changed. Use `missing` to fill in new snapshots only. Baselines live in `Tests/UISnapshotTests/__Snapshots__/<suite>/<test>.1.png` and are committed.

- **`FeatureTests`** (`Tests/FeatureTests/`) — TCA `TestStore` tests for the UI reducers, `SystemSymlinkInstallerTests` (mock-driven orchestration of the helper flow), and `BundledPlistTests` which statically reads `App/LaunchAgents/*.plist` + `App/LaunchDaemons/*.plist` and asserts every `BundleProgram` resolves to `Contents/MacOS/<tool>` — see the BundleProgram rule under "Key design details". Use `TestClock` for time-dependent effects, override `@Dependency` via `withDependencies:`. Time in state is pinned via `AppFeature.State.previewNow` so snapshot and TestStore fixtures share a clock.

- **`XcodeMCPTapUITests`** (`UITests/XcodeMCPTapUITests/`) — Xcode UI-testing bundle (not an SPM target). Launches the packaged `.app`, drives the Settings pane, clicks "Install service", waits up to 10s for the sidebar to flip to "Service running", and tears down. Catches an agent plist whose `BundleProgram` doesn't resolve — `xcmcptapd` fails with `EX_CONFIG (78)` at launchd and the sidebar stays stuck. The daemon-install flow (`/usr/local/bin` via `SMAppService.daemon`) is *not* covered: the Login Items approval requires Touch ID / admin password and cannot be automated without a user-approved MDM profile, which itself cannot be installed locally (`com.apple.servicemanagement` has `allowmanualinstall: false`). Run: `xcodebuild -project XcodeMCPTap.xcodeproj -scheme XcodeMCPTap -destination 'platform=macOS' -only-testing:XcodeMCPTapUITests test`.

**XPC session lifecycle:** `XPCSession` must be cancelled via `session.cancel(reason:)` before deallocation — otherwise it crashes with `_xpc_api_misuse`. Always use `defer { session.cancel(reason:) }`.

## Architecture

Xcode MCP Tap is a signed, notarized macOS .app that keeps a single `mcpbridge` process alive and proxies MCP connections through it — so the Xcode permission dialog only appears once.

**Communication chain:**

```
Agent ←stdio→ xcmcptap ←XPC→ xcmcptapd ←stdin/stdout→ /usr/bin/xcrun mcpbridge
                                                        (optional, privileged)
                                       ↘ XPC → xcmcptap-helper → FileManager
```

### Self-registration

The app (`App/`) handles installation; the service and helper binaries run as plain XPC listeners:
- **Launch app** (double-click .app) — `ServiceInstaller.install()` calls `SMAppService.agent(plistName:).register()` and creates `~/.local/bin/xcmcptap`.
- **Service** (launched by launchd) — `xcmcptapd` starts XPC listener, runs as persistent user agent.
- **System-path symlink** (optional, from Settings) — `SystemSymlinkInstaller.live` calls `SMAppService.daemon(plistName:).register()`, then opens an `XPCSession` to `xcmcptap-helper` running as a LaunchDaemon. The helper does `FileManager.createSymbolicLink` to `/usr/local/bin/xcmcptap`. No shell, no `osascript`. The first `register()` throws `SMAppServiceError.operationNotPermitted` until the user approves the item in System Settings > Login Items; we detect `daemon.status == .requiresApproval`, throw our own `SystemSymlinkInstallerError.requiresApproval`, and call `SMAppService.openSystemSettingsLoginItems()` so the user lands on the right pane. After the switch is on, a subsequent click succeeds silently.
- **Uninstall** — `ServiceInstaller.uninstall()` tears down the system symlink first (while the helper XPC connection is still live), then unregisters the agent and removes `~/.local/bin/xcmcptap`. `scripts/uninstall.sh` also does user-side cleanup, moves `.app` to Trash via Finder, and `sudo`-removes `/usr/local/bin/xcmcptap` + any SMAppService-staged daemon plist only if they actually exist.

### Targets

**Rule: code that can live in SPM lives in SPM.** `Sources/` is 100% SPM — libraries + two test-only executables (`xpc-test-echo-server`, `xcmcptap-helper`). `App/` is Xcode-native: the `.app` bundle's `@main` entry point and three thin `@main` tool wrappers (`xcmcptap`, `xcmcptapd`, `xcmcptap-helper`). Everything else (views, features, dependency clients, installer, system-symlink orchestration) lives in the `XcodeMCPTapUI` library so it's importable by tests and previewable from any package consumer.

**SPM libraries** (`Package.swift`, all under `Sources/`):

- **XcodeMCPTapShared** (`Sources/Shared/`) — `MCPTap` (service name constant), `MCPLine` (Codable message wrapper), `RPCMessage`/`RPCId` (JSON-RPC parsing), plus the status protocol types (`StatusRequest/Response`, `ConnectionInfo`, `ServiceHealth`, `ToolInfo`, `StatusEvent`) — all `Equatable` so they can appear in `@ObservableState`. Used by every other target.
- **XcodeMCPTapClient** (`Sources/Client/`) — Client logic: XPC session, stdin reader, stdout writer. Exposes `public enum ClientMain { public static func run() }`.
- **XcodeMCPTapService** (`Sources/Service/`) — Service logic: `BridgeProcess`, `MCPConnection`, `MCPRouter`, `ConnectionRegistry`, `StatusEndpoint`, plus `public enum ServiceMain { public static func run() }`. Imported by tests.
- **XcodeMCPTapHelper** (`Sources/Helper/`) — Privileged helper logic: `SymlinkOperations` (pure `FileManager` ops, testable in `$TMPDIR`), `HelperHandler` (request→response dispatch keyed on an injectable `destination`), and `public enum HelperMain { public static func run() }` which reads `HELPER_MACH_SERVICE` / `HELPER_DESTINATION` / `HELPER_ALLOW_ANY_PEER` from env and spins up `XPCListener(service:requirement:)`. No knowledge of `/usr/local/bin`; all paths injected.
- **XcodeMCPTapUI** (`Sources/UI/`) — SwiftUI + TCA layer. Organized into four folders:
  - `Views/` — `ContentView`, `OverviewView`, `ToolsView`, `ConnectionsView`, `SettingsView`, plus `StatusDot`, `SidebarItem`, `ToolCategory`, `formatUptime(interval:)`.
  - `Features/` — `AppFeature` (root reducer, owns global state + selection + `now`), `ToolsFeature` (search/selection sub-feature), `SettingsFeature` (copy-reset + uninstall-confirm sub-feature with a `Delegate` action that forwards install/uninstall intent to the root).
  - `Dependencies/` — `StatusClient` (wraps `XPCSession` + event stream in an actor, served via `@Dependency(\.statusClient)`), `ServiceInstallerClient` (install/uninstall/path accessors), `PasteboardClient` (NSPasteboard copy). Each exposes `liveValue` and `testValue`.
  - `DesignSystem/` — `Tokens.swift` (`Spacing`, `Radius`, `IconSize`, `SidebarWidth`, `WindowSize`, `SurfaceOpacity`, `BorderWidth` enums) and `Modifiers.swift` (`cardSurface()`, `cardBorder()`). See "UI layout conventions" below.
  - Top-level `ServiceInstaller.swift` (live impl backing `ServiceInstallerClient`, owns `installSystemSymlink` / `uninstallSystemSymlink`), `SystemSymlinkInstaller.swift` (the `register daemon → open XPC → send request → close` flow with injectable `registerDaemon` / `openHelperSession` deps for tests; `.live` value wires real `SMAppService.daemon` + `XPCSession`), and `PreviewState.swift` (`AppFeature.State.previewRunning()` etc.).
- **xpc-test-echo-server** (`Sources/TestEchoServer/`) — Test helper that echoes `MCPLine` messages back with "echo:" prefix.
- **xcmcptap-helper** (`Sources/HelperExec/`) — SPM executable wrapper calling `HelperMain.run()`. Used by `HelperEndToEndTests` as a user-level LaunchAgent; the production copy shipped inside `.app` is the Xcode-native target of the same name.
- **XPCTests** (`Tests/XPCTests/`) — Swift Testing suite: XPC echo tests, Subprocess round-trip tests, MCP proxy tests.
- **UISnapshotTests** (`Tests/UISnapshotTests/`) — Swift Testing suite: SwiftUI snapshot tests over `XcodeMCPTapUI`.
- **FeatureTests** (`Tests/FeatureTests/`) — Swift Testing suite: TCA `TestStore` tests over `AppFeature` / `ToolsFeature` / `SettingsFeature`.

**Xcode targets** (`project.yml`):

- **XcodeMCPTap** (synced folder `App/`, with `xcmcptap`/`xcmcptapd`/`xcmcptap-helper`/`LaunchAgents`/`LaunchDaemons` excluded) — macOS Application target. `App/XcodeMCPTapApp.swift` holds the `@main App` and imports `XcodeMCPTapUI`. Embeds all three tools in `Contents/MacOS/` via Copy Files, and copies `alfred.xcmcptap.plist` + `alfred.xcmcptap.helper.plist` into `Contents/Library/LaunchAgents/` and `Contents/Library/LaunchDaemons/` via dedicated `copyFiles` build phases. The excludes are emitted as a `PBXFileSystemSynchronizedBuildFileExceptionSet` so those subdirs belong exclusively to their own tool targets.
- **xcmcptap** (synced folder `App/xcmcptap/`) — Xcode command-line tool target. Single-file `@main` wrapper: `import XcodeMCPTapClient; ClientMain.run()`.
- **xcmcptapd** (synced folder `App/xcmcptapd/`) — Xcode command-line tool target. Single-file `@main` wrapper: `import XcodeMCPTapService; ServiceMain.run()`.
- **xcmcptap-helper** (synced folder `App/xcmcptap-helper/`) — Xcode command-line tool target. Single-file `@main` wrapper: `import XcodeMCPTapHelper; HelperMain.run()`.
- **XcodeMCPTapUITests** (`UITests/XcodeMCPTapUITests/`) — `bundle.ui-testing` target hosted by `XcodeMCPTap`. Covered under "Testing" above.

**Why the tool targets are Xcode-native (not SPM executables):** SPM-built executables get `com.apple.security.get-task-allow` injected into their entitlements in Release builds, and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` at the xcodebuild level does not propagate to SPM products. That entitlement fails notarization. Xcode-native tool targets respect the setting cleanly, so `project.yml` sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` at the project level and `OTHER_CODE_SIGN_FLAGS: --timestamp` in the Release config. No post-build re-signing hacks needed.

### Key design details

- **Subprocess I/O:** `BridgeProcess` uses [swift-subprocess](https://github.com/swiftlang/swift-subprocess) (not Foundation.Process). An `AsyncStream<[UInt8]>` bridges the synchronous `write()` calls (from XPC handlers) to the async `StandardInputWriter` inside the `run()` closure. `preferredBufferSize: 1` is required — larger buffers cause DispatchIO to hold back interactive output. `outputSequence.lines()` reads stdout line-by-line (strips newlines).
- **MCP init caching:** `MCPRouter` pre-initializes the bridge (sends `initialize` + `initialized` + `tools/list`), caches the init response, and replays it to each client. Messages arriving before init completes are buffered in `pendingClientMessages`.
- **Single bridge, many clients:** The service creates ONE shared `BridgeProcess` at startup and multiplexes all XPC connections through it.
- **Platform:** macOS 26.0+, Swift 6.2 with strict concurrency. Uses the `XPC` framework module directly (not the old C `xpc_*` API).
- **Entry points use `@main`, never top-level code.** `@main` goes on a type with `static func main()`. Files containing `@main` must not be named `main.swift` — that filename triggers Swift's script mode and forbids `@main`.
- **No blanket Foundation imports.** Use atomic imports (`import struct Foundation.Data`, `import class Foundation.JSONEncoder`). `Darwin.C` provides C stdlib (`fputs`, `stderr`, `pid_t`, `sleep`, `getuid`). `Dispatch` is its own module, not part of Foundation.
- **`Synchronization.Mutex` is non-copyable.** Cannot assign to a local variable or capture by value. Access through `self` when capturing in closures, or capture the owning object.
- **No crash operators.** `try!`, `as!`, force-unwrap `!`, implicitly-unwrapped optionals (`var x: T!`), `fatalError`, `preconditionFailure`, `assertionFailure` erase the underlying error. Handle it and surface a readable message instead. In tests, throw from the `throws` init or fixture so Swift Testing reports the failure — never `fatalError`.
- **Thread safety & no unsafe shortcuts.** Mutable shared state is guarded by `Synchronization.Mutex`. A class with `private let state = Mutex(...)` is genuinely `Sendable` — write `final class Foo: Sendable { ... }`, and drop the conformance entirely if the type never crosses isolations. The following "shut the checker up" escape hatches are banned, with the modern replacement in each case:
  - `@unchecked Sendable`, `nonisolated(unsafe)` → real `Sendable` backed by `Mutex`, an `actor`, or all-`let` stored properties
  - `unsafeBitCast`, `unsafeDowncast` → proper casts / explicit conversions
  - `Foundation.Process` → [swift-subprocess](https://github.com/swiftlang/swift-subprocess)
  - `NSLock` → `Synchronization.Mutex`
  - C `xpc_*` API → `XPC` framework module
  - top-level code in `main.swift` → `@main` type

  Take the extra effort even when it costs more lines. When a modern API is missing an annotation — e.g. `NotificationCenter` observer tokens come back as `any NSObjectProtocol`, which isn't `Sendable` — prefer dropping the `Sendable` conformance on the owning type over reaching for `@unchecked`.
- **TCA effects + strict concurrency:** `@Reducer struct` is not `Sendable`, so capturing `self` inside `.run { send in ... }` fails. Copy each `@Dependency` into a local before returning the effect: `let clock = self.clock; return .run { ... }`. Or make the effect body a `static` helper taking the deps as parameters.
- **Nested action enums need `@CasePathable`:** `TestStore.receive(\.delegate.install)` traverses nested case paths. The outer `Action` gets it from `@Reducer`; inner enums (e.g. `SettingsFeature.Action.Delegate`) must be annotated explicitly.
- **LaunchAgent/Daemon `BundleProgram` is rooted at the bundle, not at `Contents/`.** Always write `Contents/MacOS/<tool>` — launchd resolves the value relative to the app bundle's top-level directory, so `MacOS/xcmcptapd` silently becomes `/Applications/Xcode MCP Tap.app/MacOS/xcmcptapd`, which doesn't exist, and the service fails to spawn with `EX_CONFIG (78)` and no user-visible error. `BundledPlistTests` guards the source plists against regressions.
- **`SMAppService.daemon(...).register()` throws until the user approves in Login Items.** BTM accepts the registration, but until the user flips the switch in System Settings > Login Items (Touch ID / admin password required), the call throws `SMAppServiceError.operationNotPermitted`. Check `daemon.status == .requiresApproval` to distinguish this from a real failure. There is no way to automate the approval — the `com.apple.servicemanagement` MDM profile is the only legitimate pre-approval mechanism, and it cannot be installed locally (`allowmanualinstall: false`, requires user-approved MDM enrollment).
- **launchd caches agent/daemon jobs by Label across plist edits.** Calling `.register()` again after changing the bundled plist does not reload the job — launchd keeps the old `BundleProgram` and keeps failing on spawn. Evict with `launchctl bootout gui/$UID/<label>` (agent, no sudo) or `sudo launchctl bootout system/<label>` (daemon). `launchctl print` on the label shows the cached `program identifier` and `last exit code`. Production users don't hit this because they install once with the final plist; it's a development-workflow hazard.

### UI layout conventions

- **Use design tokens, never raw numbers.** All spacing, radii, opacities, icon sizes, sidebar widths, and border styling come from `Sources/UI/DesignSystem/Tokens.swift`. New views must read from these enums rather than introduce fresh magic numbers. Repeated card chrome uses `.cardSurface(radius:)` / `.cardBorder(radius:)` from `Modifiers.swift`.
- **Tabular layouts use `Grid` + `GridRow`,** not `HStack` with `.frame(width:)` columns. Grid auto-sizes columns to widest content and mirrors correctly under RTL — fixed widths break both. Examples: `ConnectionsView` (whole table) and `SettingsView` paths card.
- **`GridRow` modifier gotcha:** `GridRow` must be a *direct* child of `Grid`. Wrapping it in `.padding`/`.background`/`.onHover`/etc. makes the result a different view type, and `Grid` no longer treats it as a row. Workarounds: use a `@ViewBuilder` function returning `GridRow` (the call-site inlines), apply per-cell padding instead of per-row, or use `Grid`'s own `verticalSpacing:`/`horizontalSpacing:` arguments. State-bearing per-row views (`@State var hovered`) cannot be `GridRow`-typed without losing layout.
- **Truncated text needs `.minimumScaleFactor`.** Anywhere `.lineLimit(1)` guards a label that could be localized, pair it with `.minimumScaleFactor(0.85)` (or lower for large display values) so non-English strings shrink instead of clipping.
- **RTL snapshot variants are required.** Each top-level view in `Tests/UISnapshotTests/` has a `*RTL` test that wraps the view in `.environment(\.layoutDirection, .rightToLeft)`. New views add the same.
