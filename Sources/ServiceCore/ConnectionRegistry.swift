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
    var onEvent: (@Sendable (StatusEvent) -> Void)?
  }

  public var onEvent: (@Sendable (StatusEvent) -> Void)? {
    get { state.withLock { $0.onEvent } }
    set { state.withLock { $0.onEvent = newValue } }
  }

  public func register(id: UUID, bridgePID: Int32) -> ConnectionInfo {
    let info = ConnectionInfo(
      id: id,
      connectedAt: Date(),
      messagesRouted: 0,
      lastActivityAt: Date(),
      bridgePID: bridgePID
    )

    let handler = state.withLock {
      $0.connections[id] = info
      $0.totalServed += 1
      return $0.onEvent
    }

    handler?(StatusEvent(kind: .connectionOpened, connection: info))
    return info
  }

  public func unregister(id: UUID) {
    let (info, handler) = state.withLock {
      ($0.connections.removeValue(forKey: id), $0.onEvent)
    }
    if let info {
      handler?(StatusEvent(kind: .connectionClosed, connection: info))
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
          activeConnectionCount: s.connections.count
        ),
        tools: s.tools
      )
    }
  }
}
