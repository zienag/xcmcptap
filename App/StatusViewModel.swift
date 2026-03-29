import Foundation
import Observation
import XPC
import XcodeMCPTapShared
import AppKit

@Observable
final class StatusViewModel: @unchecked Sendable {
  var connections: [ConnectionInfo] = []
  var health: ServiceHealth?
  var isServiceRunning = false

  var isInstalled: Bool {
    FileManager.default.fileExists(atPath: ServiceInstaller.plistPath)
  }

  var menuBarIcon: String {
    if !isServiceRunning {
      return "xmark.circle"
    }
    if connections.isEmpty {
      return "circle.dotted"
    }
    return "circle.fill"
  }

  private var session: XPCSession?
  private var pollTimer: DispatchSourceTimer?

  init() {
    startPolling()
  }

  // MARK: - Polling

  private func startPolling() {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now(), repeating: .seconds(2))
    timer.setEventHandler { [weak self] in
      self?.poll()
    }
    timer.resume()
    pollTimer = timer
  }

  private func poll() {
    do {
      let session = try connect()
      let response: StatusResponse = try session.sendSync(StatusRequest())
      DispatchQueue.main.async { [self] in
        connections = response.connections
        health = response.health
        isServiceRunning = true
      }
    } catch {
      DispatchQueue.main.async { [self] in
        connections = []
        health = nil
        isServiceRunning = false
        session = nil
      }
    }
  }

  private func connect() throws -> XPCSession {
    if let existing = session {
      return existing
    }

    let newSession = try XPCSession(
      machService: MCPTap.statusServiceName,
      incomingMessageHandler: { [weak self] (event: StatusEvent) -> (any Encodable)? in
        DispatchQueue.main.async {
          self?.handleEvent(event)
        }
        return nil
      },
      cancellationHandler: { [weak self] _ in
        DispatchQueue.main.async {
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
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.poll()
    }
  }

  func uninstall() {
    session?.cancel(reason: "uninstalling")
    session = nil
    ServiceInstaller.uninstall()
    DispatchQueue.main.async { [self] in
      isServiceRunning = false
      connections = []
      health = nil
    }
  }

  func copyConfigCommand() {
    let command = "claude mcp add --transport stdio xcode -- \(ServiceInstaller.clientLinkPath)"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
  }
}
