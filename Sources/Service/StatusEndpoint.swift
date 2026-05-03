import struct Foundation.UUID
import Synchronization
import XcodeMCPTapShared
import XPC

public final class StatusEndpoint: Sendable {
  private let registry: ConnectionRegistry
  private let serviceName: String
  private let statusServiceName: String
  private let sessions = Mutex<[UUID: XPCSession]>([:])

  public init(registry: ConnectionRegistry, serviceName: String, statusServiceName: String) {
    self.registry = registry
    self.serviceName = serviceName
    self.statusServiceName = statusServiceName
  }

  public func start() throws -> XPCListener {
    let listener = try XPCListener(
      service: statusServiceName,
    ) { [self] request in
      let sessionID = UUID()

      let (decision, session) = request.accept(
        incomingMessageHandler: { [self] (_: StatusRequest) -> (any Encodable)? in
          registry.status()
        },
        cancellationHandler: { [self, sessionID] _ in
          sessions.withLock { _ = $0.removeValue(forKey: sessionID) }
        },
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
