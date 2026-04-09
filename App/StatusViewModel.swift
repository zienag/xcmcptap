import AppKit
import class Foundation.FileManager
import Observation
import XPC
import XcodeMCPTapShared

@MainActor @Observable
final class StatusViewModel {
  var connections: [ConnectionInfo] = []
  var health: ServiceHealth?
  var tools: [ToolInfo] = []
  var isServiceRunning = false

  var isInstalled: Bool {
    FileManager.default.fileExists(atPath: ServiceInstaller.plistPath)
  }

  private var session: XPCSession?
  private var pollTask: Task<Void, Never>?

  init() {
    startPolling()
  }

  // MARK: - Polling

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

  // MARK: - Actions

  func install() {
    ServiceInstaller.install()
    session = nil
    Task {
      try? await Task.sleep(for: .seconds(1))
      await poll()
    }
  }

  func uninstall() {
    session?.cancel(reason: "uninstalling")
    session = nil
    ServiceInstaller.uninstall()
    isServiceRunning = false
    connections = []
    health = nil
  }

  func copyConfigCommand() {
    let command = "claude mcp add --transport stdio xcode -- \(ServiceInstaller.clientLinkPath)"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
  }
}
