import struct Foundation.Data
import struct Foundation.Decimal
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import class Foundation.NSDecimalNumber
import struct Foundation.UUID
import Synchronization
import XcodeMCPTapShared

public final class MCPRouter: Sendable {
  public typealias Sleeper = @Sendable (Duration) async -> Void

  private let makeConnection: @Sendable () -> MCPConnection
  private let state = Mutex(State())
  private let healthPingInterval: Duration
  private let healthPingTimeout: Duration
  private let sleeper: Sleeper

  private struct ClientSlot: Sendable {
    var send: @Sendable (String) -> Void
  }

  private struct Mapping: Sendable {
    var client: UUID
    var original: JSONValue
  }

  /// The router has three possible bridge states. Every client message
  /// must terminate in a response (for requests) or a silent drop (for
  /// notifications) regardless of state — no message may be left
  /// hanging in `pending` without an eventual reply.
  ///
  /// - `booting`: the bridge subprocess is starting and init hasn't
  ///   completed. Messages queue in `pending` and drain once state
  ///   transitions to `.ready` or `.failed`.
  /// - `ready(cachedInit)`: normal operation. `initialize` replies are
  ///   served from the cached response; everything else is forwarded.
  /// - `failed(reason)`: the current bridge crashed. Requests arriving
  ///   while in this state get a synthesized JSON-RPC error reply
  ///   *immediately* AND trigger an auto-respawn — the next message
  ///   drives a fresh bridge attempt, so a user launching Xcode after
  ///   the first failure recovers on the next request. Notifications
  ///   are dropped silently.
  private enum BridgeState: Sendable {
    case booting
    case ready(cachedInit: RPCEnvelope)
    case failed(reason: String)
  }

  private struct State: Sendable {
    var bridge: BridgeState = .booting
    /// The subprocess transport currently owned by the router. Replaced
    /// each time `boot()` runs (initial boot + every respawn). `nil`
    /// between a failure and the next respawn, and after `shutdown()`.
    var currentConnection: MCPConnection?
    /// Set by `shutdown()` to prevent further respawns on late-arriving
    /// client messages while the router is being torn down.
    var isShutdown: Bool = false
    var pending: [(client: UUID, content: String)] = []
    var clients: [UUID: ClientSlot] = [:]
    /// bridge-facing id (canonical string) → origin client + client's id
    var idMap: [String: Mapping] = [:]
    /// bridge-facing progressToken (canonical string) → origin client + token
    var progressMap: [String: Mapping] = [:]
    var nextBridgeID: Int = 1
    var onToolsDiscovered: (@Sendable ([ToolInfo]) -> Void)?
    var onBridgeStateChanged: (@Sendable (BridgeStatus) -> Void)?
  }

  /// Computed synchronously under the state mutex by `prepareOutgoing`.
  /// Forwards to the bridge happen asynchronously AFTER the mutex is
  /// released, but the state mutations (id allocation, mapping
  /// registration, envelope rewriting) are already committed — so a
  /// follow-up message can safely look up what was just registered.
  private enum Action {
    case none
    case replyToClient(@Sendable (String) -> Void, String)
    case forwardToBridge(Data)
  }

  public var onToolsDiscovered: (@Sendable ([ToolInfo]) -> Void)? {
    get { state.withLock { $0.onToolsDiscovered } }
    set { state.withLock { $0.onToolsDiscovered = newValue } }
  }

  /// Fired on every BridgeState transition (booting → ready, booting/ready
  /// → failed, and failed → booting during auto-respawn). Used by the
  /// status endpoint to broadcast state to connected UI clients. Always
  /// called outside the state mutex.
  public var onBridgeStateChanged: (@Sendable (BridgeStatus) -> Void)? {
    get { state.withLock { $0.onBridgeStateChanged } }
    set { state.withLock { $0.onBridgeStateChanged = newValue } }
  }

  /// Primary initializer. Takes a factory so the router can spawn a
  /// fresh subprocess transport on respawn — a single `MCPConnection`
  /// value is one-shot (its subprocess runs once). Production: wrap
  /// `MCPConnection(exec: "/usr/bin/xcrun", "mcpbridge")`. Tests: vary
  /// per-attempt behavior by branching inside the closure.
  ///
  /// `healthPingInterval` / `healthPingTimeout` drive the proactive
  /// hang detector: every `interval`, while the bridge is `.ready`, we
  /// send a `tools/list` and flip to `.failed` if the response doesn't
  /// come back within `timeout`. Defaults are tuned for production;
  /// tests override to millisecond scale.
  public init(
    makeConnection: @Sendable @escaping () -> MCPConnection,
    healthPingInterval: Duration = .seconds(30),
    healthPingTimeout: Duration = .seconds(10),
    sleeper: @escaping Sleeper = { duration in
      try? await Task.sleep(for: duration)
    },
  ) {
    self.makeConnection = makeConnection
    self.healthPingInterval = healthPingInterval
    self.healthPingTimeout = healthPingTimeout
    self.sleeper = sleeper
  }

  /// Backward-compatible initializer for tests that own a single
  /// MCPConnection and never exercise respawn. Any recovery path will
  /// re-use the same dead connection, which is fine for tests that
  /// stay in `.ready`.
  public convenience init(connection: MCPConnection) {
    let captured = connection
    self.init(makeConnection: { captured })
  }

  public func start() {
    Task { await self.boot() }
    Task { await self.healthPingLoop() }
  }

  /// Register a connected client with its send callback. Use the returned
  /// id (or a UUID you already own) when calling `handleClientMessage`.
  public func registerClient(
    id: UUID = UUID(),
    send: @escaping @Sendable (String) -> Void,
  ) -> UUID {
    state.withLock { s in
      s.clients[id] = ClientSlot(send: send)
    }
    return id
  }

  /// Remove a client and drop any in-flight routing entries belonging to it.
  public func unregisterClient(id: UUID) {
    state.withLock { s in
      s.clients.removeValue(forKey: id)
      s.idMap = s.idMap.filter { $0.value.client != id }
      s.progressMap = s.progressMap.filter { $0.value.client != id }
    }
  }

  public func handleClientMessage(from clientID: UUID, _ content: String) {
    let (action, shouldRespawn, notify) = state
      .withLock { s -> (Action, Bool, (@Sendable (BridgeStatus) -> Void)?) in
        if s.isShutdown { return (.none, false, nil) }
        switch s.bridge {
        case .booting:
          s.pending.append((clientID, content))
          return (.none, false, nil)
        case .ready:
          return (
            Self.prepareOutgoing(from: clientID, content: content, state: &s),
            false,
            nil,
          )
        case .failed:
          // Auto-recover: flip to .booting, queue this message, and have
          // the caller kick off a fresh boot. If the respawn succeeds the
          // pending message gets flushed normally; if it fails again the
          // message gets an error reply. Either way the client is never
          // left hanging.
          s.bridge = .booting
          s.pending.append((clientID, content))
          return (.none, true, s.onBridgeStateChanged)
        }
      }
    perform(action)
    notify?(.booting)
    if shouldRespawn {
      Task { await self.boot() }
    }
  }

  /// Terminates the current subprocess (if any) and prevents further
  /// respawns. Idempotent. Async so callers can `await` a clean exit.
  public func shutdown() async {
    let oldConnection = state.withLock { s -> MCPConnection? in
      s.isShutdown = true
      let old = s.currentConnection
      s.currentConnection = nil
      s.bridge = .failed(reason: "router shut down")
      return old
    }
    await oldConnection?.terminate()
  }

  /// External trigger for forcing the bridge into `.failed` — used when
  /// the supervisor (NSWorkspace observer watching Xcode, periodic
  /// health-ping) decides mcpbridge is no longer usable even though the
  /// subprocess is still alive. Terminates the current subprocess so
  /// it can't continue to accept stale input, fires `onBridgeStateChanged`
  /// with the provided reason, and lets the next client message drive
  /// a respawn via the existing auto-recovery path.
  public func markBridgeUnavailable(reason: String) async {
    let connection = state.withLock { $0.currentConnection }
    if let connection {
      markBridgeFailed(reason: reason, failingConnection: connection)
    } else {
      let notify = state.withLock { s -> (@Sendable (BridgeStatus) -> Void)? in
        switch s.bridge {
        case .failed: return nil
        case .booting, .ready:
          s.bridge = .failed(reason: reason)
          return s.onBridgeStateChanged
        }
      }
      notify?(.failed(reason: reason))
    }
  }

  // MARK: - Private

  /// Loops for the lifetime of the router. Every `healthPingInterval`,
  /// while the bridge is `.ready`, sends a lightweight `tools/list`
  /// and races it against `healthPingTimeout`. A timeout flips the
  /// bridge to `.failed` — catches the "Xcode quit but mcpbridge is
  /// still alive and hanging" mode that otherwise only surfaces on
  /// the next client tool call. Silent on `.booting` / `.failed`.
  private func healthPingLoop() async {
    while !Task.isCancelled {
      await sleeper(healthPingInterval)
      let (connection, isShutdown) = state.withLock { s -> (MCPConnection?, Bool) in
        guard case .ready = s.bridge else { return (nil, s.isShutdown) }
        return (s.currentConnection, s.isShutdown)
      }
      if isShutdown { return }
      guard let connection else { continue }
      let ok = await raceRequestAgainstTimeout(connection: connection)
      if !ok {
        await markBridgeUnavailable(
          reason: "mcpbridge not responding to health ping",
        )
      }
    }
  }

  /// Sends `tools/list` and returns `true` if the response came back
  /// within `healthPingTimeout`, `false` otherwise. Doesn't use
  /// `withTaskGroup` + `cancelAll` because `MCPConnection.request`
  /// awaits a response that will never arrive on a hung bridge and
  /// doesn't cooperate with task cancellation — the task group would
  /// deadlock waiting for the hung child. Instead: detach the request,
  /// sleep the timeout, read a flag. The orphaned task is harmless
  /// since the caller terminates the subprocess on timeout, which
  /// unblocks it.
  private func raceRequestAgainstTimeout(connection: MCPConnection) async -> Bool {
    let completed = Mutex(false)
    Task {
      do {
        _ = try await connection.request(
          method: "tools/list",
          params: .object([:]),
        )
        completed.withLock { $0 = true }
      } catch {
        // request failed — leave `completed` as false so the caller
        // flags the ping as a miss and drives recovery.
      }
    }
    await sleeper(healthPingTimeout)
    return completed.withLock { $0 }
  }

  private func boot() async {
    let connection = makeConnection()
    state.withLock { $0.currentConnection = connection }

    await connection.start()

    // The passthrough drain lives alongside boot — it's tied to THIS
    // connection's lifetime. When the subprocess dies, it ends and
    // flips state to `.failed`.
    Task { await self.drainPassthrough(connection: connection) }

    do {
      let initResponse = try await connection.request(
        method: "initialize",
        params: MCPProtocol.initializeParams(
          clientName: "XcodeMCPTap",
          clientVersion: "1.0",
        ),
      )
      try await connection.notify(method: "notifications/initialized")

      // Flush buffered messages synchronously under the lock so ordering
      // between two buffered messages from the same client is preserved
      // — e.g. a cancel following its tools/call sees the just-registered
      // mapping.
      let (actions, notify) = state
        .withLock { s -> ([Action], (@Sendable (BridgeStatus) -> Void)?) in
          s.bridge = .ready(cachedInit: initResponse)
          let flushed = s.pending
          s.pending = []
          let acts = flushed.map { entry in
            Self.prepareOutgoing(from: entry.client, content: entry.content, state: &s)
          }
          return (acts, s.onBridgeStateChanged)
        }
      for action in actions {
        perform(action)
      }
      notify?(.ready)
    } catch {
      let reason = await formatBridgeFailure(connection: connection, error: error)
      markBridgeFailed(reason: reason, failingConnection: connection)
      return
    }

    Task {
      guard let response = try? await connection.request(
        method: "tools/list",
        params: .object([:]),
      ) else { return }
      guard case let .object(result)? = response.rest["result"],
            case let .array(tools)? = result["tools"] else { return }
      let infos = tools.compactMap { t -> ToolInfo? in
        guard case let .object(o) = t, case let .string(name)? = o["name"] else { return nil }
        let description: String = if case let .string(d)? = o["description"] { d } else { "" }
        return ToolInfo(name: name, description: description)
      }
      let handler = state.withLock { $0.onToolsDiscovered }
      handler?(infos)
    }
  }

  private func drainPassthrough(connection: MCPConnection) async {
    for await line in connection.passthrough {
      guard let str = String(bytes: line, encoding: .utf8) else { continue }
      deliverFromBridge(str)
    }
    // Passthrough stream ended — the subprocess exited. Only transition
    // if this connection is still the current one (a stale drain from a
    // previous-generation connection must not clobber a fresh boot).
    let isCurrent = state.withLock { s in s.currentConnection === connection }
    if isCurrent {
      let reason = await formatBridgeFailure(
        connection: connection,
        error: MCPConnectionError.transportClosed,
      )
      markBridgeFailed(reason: reason, failingConnection: connection)
    }
  }

  private func formatBridgeFailure(connection: MCPConnection, error: any Error) async -> String {
    let stderr = await connection.recentStderr
    let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedStderr.isEmpty {
      return "mcpbridge unavailable: \(trimmedStderr)"
    }
    return "mcpbridge unavailable: \(error)"
  }

  /// Transition to `.failed` and drain everything waiting on a response
  /// — both in-flight mapped requests and the pending queue. Idempotent:
  /// a second call after state is already `.failed` is a no-op, so
  /// boot-failure and passthrough-closure can race safely. The old
  /// connection is terminated asynchronously so the mutex stays short.
  private func markBridgeFailed(reason: String, failingConnection: MCPConnection) {
    let (actions, oldConnection, notify) = state
      .withLock { s -> ([Action], MCPConnection?, (@Sendable (BridgeStatus) -> Void)?) in
        // Only transition if the failing connection is still current —
        // stale drains from a previous-generation bridge must be ignored.
        guard s.currentConnection === failingConnection else { return ([], nil, nil) }
        switch s.bridge {
        case .failed:
          return ([], nil, nil)
        case .booting, .ready:
          break
        }
        s.bridge = .failed(reason: reason)
        let old = s.currentConnection
        s.currentConnection = nil

        var out: [Action] = []

        // Fail every in-flight mapped request — the bridge will never
        // reply to them.
        for mapping in s.idMap.values {
          guard let slot = s.clients[mapping.client] else { continue }
          if let line = Self.encodeError(id: mapping.original, reason: reason) {
            out.append(.replyToClient(slot.send, line))
          }
        }
        s.idMap.removeAll()
        s.progressMap.removeAll()

        // Flush anything still in the pending queue back through
        // `prepareOutgoing`, which now sees state `.failed` and returns
        // error replies (for requests) or drops (for notifications).
        let queued = s.pending
        s.pending = []
        for entry in queued {
          out.append(Self.prepareOutgoing(from: entry.client, content: entry.content, state: &s))
        }
        return (out, old, s.onBridgeStateChanged)
      }
    for action in actions {
      perform(action)
    }
    notify?(.failed(reason: reason))
    if let old = oldConnection {
      Task { await old.terminate() }
    }
  }

  private func deliverFromBridge(_ raw: String) {
    guard var envelope = try? JSONDecoder().decode(
      RPCEnvelope.self, from: Data(raw.utf8),
    ) else { return }

    // Response to a client request: look up bridge id → origin.
    if let id = envelope.id, let key = Self.idKey(id) {
      let resolved = state.withLock { s -> (send: @Sendable (String) -> Void, original: JSONValue)? in
        guard let mapping = s.idMap.removeValue(forKey: key) else { return nil }
        guard let slot = s.clients[mapping.client] else { return nil }
        return (slot.send, mapping.original)
      }
      if let resolved {
        envelope.id = resolved.original
        if let data = try? JSONEncoder().encode(envelope),
           let line = String(data: data, encoding: .utf8)
        {
          resolved.send(line)
        }
      }
      return
    }

    // Progress notification: tied to an originally-allocated bridge token.
    if envelope.method == "notifications/progress",
       case var .object(params)? = envelope.rest["params"],
       let token = params["progressToken"],
       let key = Self.idKey(token)
    {
      let resolved = state.withLock { s -> (send: @Sendable (String) -> Void, original: JSONValue)? in
        guard let mapping = s.progressMap[key] else { return nil }
        guard let slot = s.clients[mapping.client] else { return nil }
        return (slot.send, mapping.original)
      }
      if let resolved {
        params["progressToken"] = resolved.original
        envelope.rest["params"] = .object(params)
        if let data = try? JSONEncoder().encode(envelope),
           let line = String(data: data, encoding: .utf8)
        {
          resolved.send(line)
        }
      }
      return
    }

    // Uncorrelated server-initiated notifications (tools/list_changed, etc.)
    // are broadcast to every connected client.
    let recipients = state.withLock { s in s.clients.values.map(\.send) }
    for send in recipients {
      send(raw)
    }
  }

  private func perform(_ action: Action) {
    switch action {
    case .none:
      return
    case let .replyToClient(send, line):
      send(line)
    case let .forwardToBridge(data):
      // Snapshot the current connection at perform-time. If state has
      // been torn down between prepare and perform, drop — an error
      // for a mapped id already went out via `markBridgeFailed`.
      let conn = state.withLock { $0.currentConnection }
      guard let conn else { return }
      Task { try? await conn.forward(data) }
    }
  }

  /// Everything synchronous about routing a client message — envelope
  /// parsing, bridge-id allocation, mapping registration, and rewriting.
  /// Runs under the state mutex so two rapid messages from the same
  /// client (e.g. tools/call followed immediately by
  /// notifications/cancelled) are serialized and the cancel reliably
  /// observes the mapping the tools/call just installed.
  ///
  /// Never called while `state.bridge == .booting` — the caller queues
  /// in `pending` instead. Called once bridge is `.ready` or `.failed`;
  /// both paths are handled per-message type below.
  private static func prepareOutgoing(
    from clientID: UUID,
    content: String,
    state s: inout State,
  ) -> Action {
    guard let envelope = try? JSONDecoder().decode(
      RPCEnvelope.self, from: Data(content.utf8),
    ) else {
      // Unparseable. Forward only if the bridge is alive — a dead bridge
      // has no way to produce a meaningful response, so drop rather than
      // risk forwarding garbage into a pipe that's closing.
      if case .ready = s.bridge {
        return .forwardToBridge(Data(content.utf8))
      }
      return .none
    }

    switch envelope.method {
    case "initialize":
      guard let slot = s.clients[clientID] else { return .none }
      switch s.bridge {
      case .booting:
        return .none // unreachable — handleClientMessage queues instead
      case let .ready(cached):
        var response = cached
        response.id = envelope.id
        guard let data = try? JSONEncoder().encode(response),
              let line = String(data: data, encoding: .utf8) else { return .none }
        return .replyToClient(slot.send, line)
      case let .failed(reason):
        guard let id = envelope.id,
              let line = encodeError(id: id, reason: reason) else { return .none }
        return .replyToClient(slot.send, line)
      }

    case "notifications/initialized":
      return .none

    case "notifications/cancelled":
      // Cancel against a dead bridge has nothing to target — drop.
      if case .failed = s.bridge { return .none }
      var rewritten = envelope
      if case var .object(params)? = envelope.rest["params"],
         let origRequestId = params["requestId"],
         let origKey = idKey(origRequestId)
      {
        let bridgeId = s.idMap.first(where: { _, mapping in
          mapping.client == clientID && idKey(mapping.original) == origKey
        })?.key
        if let bridgeId, let bridgeInt = Int(bridgeId) {
          params["requestId"] = .number(Decimal(bridgeInt))
          rewritten.rest["params"] = .object(params)
        }
      }
      guard let data = try? JSONEncoder().encode(rewritten) else { return .none }
      return .forwardToBridge(data)

    default:
      break
    }

    // Default path: a request (has id) or any other client notification.
    // Dead bridge → error responses for requests, silent drops for
    // notifications. Live bridge → rewrite id + progressToken, forward.
    if case let .failed(reason) = s.bridge {
      guard let slot = s.clients[clientID], let id = envelope.id else {
        return .none // notification: drop
      }
      guard let line = encodeError(id: id, reason: reason) else { return .none }
      return .replyToClient(slot.send, line)
    }

    var rewritten = envelope
    if let originalId = envelope.id {
      let bridgeId = s.nextBridgeID
      s.nextBridgeID += 1
      s.idMap[String(bridgeId)] = Mapping(client: clientID, original: originalId)
      rewritten.id = .number(Decimal(bridgeId))
    }

    if case var .object(params)? = envelope.rest["params"] {
      if case var .object(meta)? = params["_meta"],
         let originalToken = meta["progressToken"]
      {
        let bridgeToken = s.nextBridgeID
        s.nextBridgeID += 1
        s.progressMap[String(bridgeToken)] = Mapping(client: clientID, original: originalToken)
        meta["progressToken"] = .number(Decimal(bridgeToken))
        params["_meta"] = .object(meta)
        rewritten.rest["params"] = .object(params)
      }
    }

    guard let data = try? JSONEncoder().encode(rewritten) else { return .none }
    return .forwardToBridge(data)
  }

  /// Encodes a JSON-RPC error reply preserving the client's id.
  /// Uses `-32603` (internal error) per the JSON-RPC spec — the bridge
  /// is unavailable rather than the client having sent a bad request.
  private static func encodeError(id: JSONValue, reason: String) -> String? {
    let envelope = RPCEnvelope(
      id: id,
      rest: [
        "jsonrpc": .string("2.0"),
        "error": .object([
          "code": .number(Decimal(-32603)),
          "message": .string(reason),
        ]),
      ],
    )
    guard let data = try? JSONEncoder().encode(envelope),
          let line = String(data: data, encoding: .utf8) else { return nil }
    return line
  }

  /// Canonicalizes a JSON-RPC id or progress token to a string key so that
  /// integer `N` and string `"N"` collapse to the same map entry — real
  /// mcpbridge sometimes stringifies progressTokens on the way back.
  private static func idKey(_ value: JSONValue) -> String? {
    switch value {
    case let .number(n):
      String(NSDecimalNumber(decimal: n).int64Value)
    case let .string(s):
      s
    default:
      nil
    }
  }
}
