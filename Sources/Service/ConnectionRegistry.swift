import struct Foundation.Date
import struct Foundation.UUID
import Synchronization
import XcodeMCPTapShared

public final class ConnectionRegistry: Sendable {
  private let state = Mutex(State())
  private let startedAt = Date()

  public init() {}

  private struct State: Sendable {
    var connections: [UUID: ConnectionInfo] = [:]
    var totalServed = 0
    var tools: [ToolInfo] = []
    var bridge: BridgeStatus = .booting
    var onEvent: (@Sendable (StatusEvent) -> Void)?
  }

  public var onEvent: (@Sendable (StatusEvent) -> Void)? {
    get { state.withLock { $0.onEvent } }
    set { state.withLock { $0.onEvent = newValue } }
  }

  public func register(id: UUID, clientPID: Int32) -> ConnectionInfo {
    let info = ConnectionInfo(
      id: id,
      connectedAt: Date(),
      messagesRouted: 0,
      lastActivityAt: Date(),
      clientPID: clientPID,
    )

    let handler = state.withLock {
      $0.connections[id] = info
      $0.totalServed += 1
      return $0.onEvent
    }

    handler?(.connectionOpened(info))
    return info
  }

  /// Overwrite the connection's `clientPID`. The service registers each
  /// connection with a placeholder `0` at XPC-accept time — the peer's
  /// PID isn't available then — and fills in the real value when the
  /// first `MCPLine` arrives carrying `clientPID`.
  public func updateClientPID(id: UUID, pid: Int32) {
    state.withLock { $0.connections[id]?.clientPID = pid }
  }

  public func unregister(id: UUID) {
    let (info, handler) = state.withLock {
      ($0.connections.removeValue(forKey: id), $0.onEvent)
    }
    if let info {
      handler?(.connectionClosed(info))
    }
  }

  public func updateBridge(_ status: BridgeStatus) {
    let (changed, handler) = state.withLock { s -> (Bool, (@Sendable (StatusEvent) -> Void)?) in
      guard s.bridge != status else { return (false, nil) }
      s.bridge = status
      return (true, s.onEvent)
    }
    if changed {
      handler?(.bridgeStateChanged(status))
    }
  }

  public func recordMessage(id: UUID) {
    state.withLock {
      $0.connections[id]?.messagesRouted += 1
      $0.connections[id]?.lastActivityAt = Date()
    }
  }

  public func updateTools(_ tools: [ToolInfo]) {
    state.withLock { $0.tools = tools }
  }

  public func status() -> StatusResponse {
    state.withLock { s in
      StatusResponse(
        connections: s.connections.values.sorted { $0.connectedAt < $1.connectedAt },
        health: ServiceHealth(
          startedAt: startedAt,
          totalConnectionsServed: s.totalServed,
          activeConnectionCount: s.connections.count,
        ),
        tools: s.tools,
        bridge: s.bridge,
      )
    }
  }
}
