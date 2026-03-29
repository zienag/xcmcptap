import struct Foundation.Date
import struct Foundation.UUID
import Synchronization
import XcodeMCPTapShared

final class ConnectionRegistry: @unchecked Sendable {
  private let state = Mutex(State())
  private let startedAt = Date()

  var onEvent: (@Sendable (StatusEvent) -> Void)?

  private struct State: Sendable {
    var connections: [UUID: ConnectionInfo] = [:]
    var totalServed = 0
  }

  func register(id: UUID, bridgePID: Int32) -> ConnectionInfo {
    let info = ConnectionInfo(
      id: id,
      connectedAt: Date(),
      messagesRouted: 0,
      lastActivityAt: Date(),
      bridgePID: bridgePID
    )

    state.withLock {
      $0.connections[id] = info
      $0.totalServed += 1
    }

    onEvent?(StatusEvent(kind: .connectionOpened, connection: info))
    return info
  }

  func unregister(id: UUID) {
    let info = state.withLock { $0.connections.removeValue(forKey: id) }
    if let info {
      onEvent?(StatusEvent(kind: .connectionClosed, connection: info))
    }
  }

  func recordMessage(id: UUID) {
    state.withLock {
      $0.connections[id]?.messagesRouted += 1
      $0.connections[id]?.lastActivityAt = Date()
    }
  }

  func status() -> StatusResponse {
    state.withLock { s in
      StatusResponse(
        connections: s.connections.values.sorted { $0.connectedAt < $1.connectedAt },
        health: ServiceHealth(
          startedAt: startedAt,
          totalConnectionsServed: s.totalServed,
          activeConnectionCount: s.connections.count
        )
      )
    }
  }
}
