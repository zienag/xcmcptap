import struct Foundation.UUID
import Synchronization
import XPC
import XcodeMCPShared

final class StatusEndpoint: @unchecked Sendable {
  private let registry: ConnectionRegistry
  private let sessions = Mutex<[UUID: XPCSession]>([:])

  init(registry: ConnectionRegistry) {
    self.registry = registry
  }

  func start() throws -> XPCListener {
    let listener = try XPCListener(
      service: MCPProxy.statusServiceName
    ) { [self] request in
      let sessionID = UUID()

      let (decision, session) = request.accept(
        incomingMessageHandler: { [self] (_: StatusRequest) -> (any Encodable)? in
          registry.status()
        },
        cancellationHandler: { [self, sessionID] _ in
          sessions.withLock { _ = $0.removeValue(forKey: sessionID) }
        }
      )

      sessions.withLock { $0[sessionID] = session }

      return decision
    }

    registry.onEvent = { [weak self] event in
      self?.broadcast(event)
    }

    return listener
  }

  private func broadcast(_ event: StatusEvent) {
    let current = sessions.withLock { Array($0.values) }
    for session in current {
      try? session.send(event)
    }
  }
}
