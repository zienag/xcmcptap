import AppKit
import struct Foundation.Date
import class Foundation.FileManager
import struct Foundation.UUID
import Observation
import XPC
import XcodeMCPTapShared

@MainActor @Observable
public final class StatusViewModel {
  public var connections: [ConnectionInfo] = []
  public var health: ServiceHealth?
  public var tools: [ToolInfo] = []
  public var isServiceRunning = false
  public var isInstalled: Bool

  @ObservationIgnored
  public var nowProvider: () -> Date = { Date() }

  public var clientPath: String { ServiceInstaller.clientLinkPath }
  public var plistPath: String { ServiceInstaller.plistPath }
  public var logPath: String { ServiceInstaller.logPath }

  public var mcpConfigCommand: String {
    "claude mcp add --transport stdio xcode -- \(ServiceInstaller.clientLinkPath)"
  }

  public var uptimeText: String? {
    guard let health else { return nil }
    let interval = max(0, nowProvider().timeIntervalSince(health.startedAt))
    return formatUptime(interval: interval)
  }

  private var session: XPCSession?
  private var pollTask: Task<Void, Never>?

  public init() {
    self.isInstalled = FileManager.default.fileExists(atPath: ServiceInstaller.plistPath)
    startPolling()
  }

  /// Builds a model with no XPC polling for use in SwiftUI previews and snapshot tests.
  public init(previewing _: Void) {
    self.isInstalled = false
  }

  private func startPolling() {
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.poll()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  private func poll() async {
    do {
      let session = try connect()
      let response: StatusResponse = try await Task.detached {
        try session.sendSync(StatusRequest())
      }.value
      connections = response.connections
      health = response.health
      tools = response.tools
      isServiceRunning = true
    } catch {
      connections = []
      health = nil
      tools = []
      isServiceRunning = false
      session = nil
    }
  }

  private func connect() throws -> XPCSession {
    if let existing = session {
      return existing
    }

    let newSession = try XPCSession(
      machService: MCPTap.statusServiceName,
      incomingMessageHandler: { [weak self] (event: StatusEvent) -> (any Encodable)? in
        Task { @MainActor in
          self?.handleEvent(event)
        }
        return nil
      },
      cancellationHandler: { [weak self] _ in
        Task { @MainActor in
          self?.session = nil
          self?.isServiceRunning = false
        }
      }
    )

    session = newSession
    return newSession
  }

  private func handleEvent(_ event: StatusEvent) {
    switch event.kind {
    case .connectionOpened:
      if !connections.contains(where: { $0.id == event.connection.id }) {
        connections.append(event.connection)
      }
    case .connectionClosed:
      connections.removeAll { $0.id == event.connection.id }
    }
  }

  public func install() {
    ServiceInstaller.install()
    isInstalled = true
    session = nil
    Task {
      try? await Task.sleep(for: .seconds(1))
      await poll()
    }
  }

  public func uninstall() {
    session?.cancel(reason: "uninstalling")
    session = nil
    ServiceInstaller.uninstall()
    isInstalled = false
    isServiceRunning = false
    connections = []
    health = nil
  }

  public func copyConfigCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(mcpConfigCommand, forType: .string)
  }
}

extension StatusViewModel {
  /// Fixed reference time for deterministic previews and snapshot tests.
  static let previewNow = Date(timeIntervalSince1970: 1_700_000_000)

  public static func previewRunning() -> StatusViewModel {
    let now = previewNow
    let model = StatusViewModel(previewing: ())
    model.nowProvider = { now }
    model.isInstalled = true
    model.isServiceRunning = true
    model.tools = sampleTools
    model.connections = sampleConnections(relativeTo: now)
    model.health = ServiceHealth(
      startedAt: now.addingTimeInterval(-(2 * 3600 + 47 * 60 + 12)),
      totalConnectionsServed: 18,
      activeConnectionCount: model.connections.count
    )
    return model
  }

  public static func previewIdle() -> StatusViewModel {
    let now = previewNow
    let model = StatusViewModel(previewing: ())
    model.nowProvider = { now }
    model.isInstalled = true
    model.isServiceRunning = true
    model.tools = sampleTools
    model.connections = []
    model.health = ServiceHealth(
      startedAt: now.addingTimeInterval(-42),
      totalConnectionsServed: 0,
      activeConnectionCount: 0
    )
    return model
  }

  public static func previewNotInstalled() -> StatusViewModel {
    let model = StatusViewModel(previewing: ())
    model.nowProvider = { previewNow }
    model.isInstalled = false
    model.isServiceRunning = false
    return model
  }

  public static let sampleTools: [ToolInfo] = [
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

  public static func sampleConnections(relativeTo now: Date) -> [ConnectionInfo] {
    [
      .init(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        connectedAt: now.addingTimeInterval(-1247),
        messagesRouted: 184,
        lastActivityAt: now.addingTimeInterval(-2),
        bridgePID: 81234
      ),
      .init(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        connectedAt: now.addingTimeInterval(-312),
        messagesRouted: 27,
        lastActivityAt: now.addingTimeInterval(-58),
        bridgePID: 81245
      ),
      .init(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        connectedAt: now.addingTimeInterval(-44),
        messagesRouted: 4,
        lastActivityAt: now.addingTimeInterval(-12),
        bridgePID: 81260
      ),
    ]
  }
}
