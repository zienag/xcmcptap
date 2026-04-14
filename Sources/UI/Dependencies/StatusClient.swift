import ComposableArchitecture
import XcodeMCPTapShared
import XPC

@DependencyClient
public struct StatusClient: Sendable {
  public var fetch: @Sendable () async throws -> StatusResponse
  public var events: @Sendable () -> AsyncStream<StatusEvent> = { .finished }
}

extension StatusClient: DependencyKey {
  public static let liveValue: StatusClient = {
    let connection = StatusConnection()
    return StatusClient(
      fetch: { try await connection.fetch() },
      events: { connection.events },
    )
  }()

  public static let testValue = StatusClient()
}

public extension DependencyValues {
  var statusClient: StatusClient {
    get { self[StatusClient.self] }
    set { self[StatusClient.self] = newValue }
  }
}

private final actor StatusConnection {
  private var session: XPCSession?
  private let continuation: AsyncStream<StatusEvent>.Continuation
  nonisolated let events: AsyncStream<StatusEvent>

  init() {
    var c: AsyncStream<StatusEvent>.Continuation!
    events = AsyncStream { c = $0 }
    continuation = c
  }

  func fetch() async throws -> StatusResponse {
    let session = try ensureSession()
    return try await Task.detached {
      try session.sendSync(StatusRequest())
    }.value
  }

  private func ensureSession() throws -> XPCSession {
    if let session { return session }
    let continuation = continuation
    let session = try XPCSession(
      machService: MCPTap.statusServiceName,
      incomingMessageHandler: { (event: StatusEvent) -> (any Encodable)? in
        continuation.yield(event)
        return nil
      },
      cancellationHandler: { [weak self] _ in
        Task { await self?.clearSession() }
      },
    )
    self.session = session
    return session
  }

  private func clearSession() {
    session?.cancel(reason: "connection cleared")
    session = nil
  }

  deinit {
    continuation.finish()
    session?.cancel(reason: "deinit")
  }
}
