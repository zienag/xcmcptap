import struct Foundation.Date
import struct Foundation.UUID
import XcodeMCPTapShared

public extension AppFeature.State {
  /// Fixed reference time for deterministic previews and snapshot tests.
  static let previewNow = Date(timeIntervalSince1970: 1_700_000_000)

  /// Fixed version label for deterministic previews and snapshot tests.
  static let previewAppVersion = "1.0.0"

  /// Stable path values for deterministic snapshot output. Paths point at
  /// guaranteed-absent locations so `FileManager.fileExists(atPath:)` is
  /// always `false`, regardless of whether the host dev machine happens to
  /// have the real app installed.
  private static let previewPlistPath =
    "/Applications/XcodeMCPTapPreview.app/Contents/Library/LaunchAgents/alfred.xcmcptap.plist"
  private static let previewClientPath = "/Users/preview/.local/bin/xcmcptap"

  private static func withPreviewPaths(_ state: AppFeature.State) -> AppFeature.State {
    var state = state
    state.plistPath = previewPlistPath
    state.clientPath = previewClientPath
    state.appVersion = previewAppVersion
    return state
  }

  static func previewRunning() -> AppFeature.State {
    let now = previewNow
    return withPreviewPaths(
      AppFeature.State(
        bridgeStatus: .ready,
        connections: sampleConnections(relativeTo: now),
        health: ServiceHealth(
          startedAt: now.addingTimeInterval(-(2 * 3600 + 47 * 60 + 12)),
          totalConnectionsServed: 18,
          activeConnectionCount: 3,
        ),
        isInstalled: true,
        isServiceRunning: true,
        now: now,
        tools: ToolsFeature.State(tools: sampleTools),
      ),
    )
  }

  static func previewBridgeBooting() -> AppFeature.State {
    var state = previewRunning()
    state.bridgeStatus = .booting
    state.connections = []
    return state
  }

  static func previewBridgeFailed() -> AppFeature.State {
    var state = previewRunning()
    state.bridgeStatus = .failed(
      reason: "mcpbridge unavailable: FATAL_NO_XCODE — launch Xcode to reconnect",
    )
    state.connections = []
    return state
  }

  static func previewIdle() -> AppFeature.State {
    let now = previewNow
    return withPreviewPaths(
      AppFeature.State(
        connections: [],
        health: ServiceHealth(
          startedAt: now.addingTimeInterval(-42),
          totalConnectionsServed: 0,
          activeConnectionCount: 0,
        ),
        isInstalled: true,
        isServiceRunning: true,
        now: now,
        tools: ToolsFeature.State(tools: sampleTools),
      ),
    )
  }

  static func previewNotInstalled() -> AppFeature.State {
    withPreviewPaths(
      AppFeature.State(
        isInstalled: false,
        isServiceRunning: false,
        now: previewNow,
      ),
    )
  }

  static let sampleTools: [ToolInfo] = [
    .init(name: "BuildProject", description: "Builds an Xcode project and waits until the build completes."),
    .init(name: "GetBuildLog", description: "Gets the log of the current or most recently finished build with optional filtering."),
    .init(name: "GetTestList", description: "Returns the test list discovered for the current scheme."),
    .init(name: "RunAllTests", description: "Runs every test in the current scheme."),
    .init(name: "RunSomeTests", description: "Runs a subset of tests selected by identifier."),
    .init(name: "RenderPreview", description: "Builds and renders a SwiftUI #Preview, returning a snapshot of the resulting UI."),
    .init(name: "ExecuteSnippet", description: "Evaluates a Swift snippet inside an Xcode Playground."),
    .init(name: "DocumentationSearch", description: "Searches Apple developer documentation for a query string."),
    .init(name: "XcodeRead", description: "Reads a file from disk inside the workspace."),
    .init(name: "XcodeWrite", description: "Writes a file to disk inside the workspace."),
    .init(name: "XcodeUpdate", description: "Performs an in-place edit on a file inside the workspace."),
    .init(name: "XcodeGlob", description: "Finds files matching a glob pattern inside the workspace."),
    .init(name: "XcodeGrep", description: "Searches the contents of files inside the workspace."),
    .init(name: "XcodeLS", description: "Lists files in a directory inside the workspace."),
    .init(name: "XcodeMV", description: "Moves a file inside the workspace."),
    .init(name: "XcodeRM", description: "Removes a file inside the workspace."),
    .init(name: "XcodeMakeDir", description: "Creates a directory inside the workspace."),
    .init(name: "XcodeListWindows", description: "Lists currently open Xcode windows."),
    .init(name: "XcodeListNavigatorIssues", description: "Lists issues currently shown in Xcode's issue navigator."),
    .init(name: "XcodeRefreshCodeIssuesInFile", description: "Forces Xcode to refresh diagnostics for a single file."),
  ]

  static func sampleConnections(relativeTo now: Date) -> [ConnectionInfo] {
    [
      .init(
        id: previewUUID(0x11),
        connectedAt: now.addingTimeInterval(-1247),
        messagesRouted: 184,
        lastActivityAt: now.addingTimeInterval(-2),
        clientPID: 81234,
      ),
      .init(
        id: previewUUID(0x22),
        connectedAt: now.addingTimeInterval(-312),
        messagesRouted: 27,
        lastActivityAt: now.addingTimeInterval(-58),
        clientPID: 81245,
      ),
      .init(
        id: previewUUID(0x33),
        connectedAt: now.addingTimeInterval(-44),
        messagesRouted: 4,
        lastActivityAt: now.addingTimeInterval(-12),
        clientPID: 81260,
      ),
    ]
  }

  /// Deterministic UUID builder for previews and tests. Every byte is `b`, so
  /// `previewUUID(0x11)` yields `11111111-1111-1111-1111-111111111111`.
  static func previewUUID(_ b: UInt8) -> UUID {
    UUID(uuid: (b, b, b, b, b, b, b, b, b, b, b, b, b, b, b, b))
  }
}
