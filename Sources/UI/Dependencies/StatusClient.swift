import ComposableArchitecture
import XcodeMCPTapShared
import XPC

@DependencyClient
public struct StatusClient: Sendable {
  public var fetch: @Sendable () async throws -> StatusResponse
  public var events: @Sendable () -> AsyncStream<StatusEvent> = { .finished }
}

public extension StatusClient {
  /// Wires a real `XPCSession` to the status endpoint at `statusServiceName`.
  /// The @main wrapper passes the value derived from the build's identity
  /// via `prepareDependencies { $0.statusClient = .live(...) }`.
  static func live(statusServiceName: String) -> StatusClient {
    let connection = StatusConnection(statusServiceName: statusServiceName)
    return StatusClient(
      fetch: { try await connection.fetch() },
      events: { connection.events },
    )
  }
}

extension StatusClient: DependencyKey {
  /// The unconfigured liveValue — fetches and the event stream act as if
  /// the service is unreachable. Production callers MUST replace this
  /// with `StatusClient.live(statusServiceName:)` via `prepareDependencies`
  /// before the dependency is read.
  public static let liveValue = StatusClient()
  public static let testValue = StatusClient()
}

public extension DependencyValues {
  var statusClient: StatusClient {
    get { self[StatusClient.self] }
    set { self[StatusClient.self] = newValue }
  }
}

private final actor StatusConnection {
  private let statusServiceName: String
  private var session: XPCSession?
  private let continuation: AsyncStream<StatusEvent>.Continuation
  nonisolated let events: AsyncStream<StatusEvent>

  init(statusServiceName: String) {
    self.statusServiceName = statusServiceName
    let stream = AsyncStream<StatusEvent>.makeStream()
    events = stream.stream
    continuation = stream.continuation
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
      machService: statusServiceName,
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
