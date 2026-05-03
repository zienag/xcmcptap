import struct Foundation.Data
import struct Foundation.Decimal
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import class Foundation.NSDecimalNumber
import struct Foundation.UUID
import os
import Synchronization
import XcodeMCPTapShared

public final class MCPRouter: Sendable {
  public typealias Sleeper = @Sendable (Duration) async -> Void

  private let log: Logger
  /// Client name advertised in the MCP `initialize` handshake. Xcode
  /// displays this string in its "<X> wants to use Xcode's tools"
  /// permission dialog, so it must vary per build variant — Release
  /// passes "Xcode MCP Tap", Dev passes "Xcode MCP Tap Dev".
  private let clientName: String
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
  /// - `failed(reason)`: the current bridge has crashed or never came
  ///   up. The proxy switches to fallback mode: `initialize` and
  ///   `tools/list` are answered locally with a synthetic init response
  ///   and a tiny built-in toolset (`xcmcptap_status`, `xcmcptap_reload`).
  ///   Status is read-only inspection; reload is the explicit recovery
  ///   path that drives a fresh boot and broadcasts
  ///   `notifications/tools/list_changed` to all clients on success so
  ///   they re-fetch the real Xcode tools. Notifications are dropped.
  private enum BridgeState: Sendable {
    case booting
    case ready(cachedInit: RPCEnvelope)
    case failed(reason: String)
  }

  /// A pending `xcmcptap_reload` request. The reply is deferred until
  /// the boot triggered by the reload completes — at which point the
  /// waiter is replied to with a success or `isError` tool result.
  private struct ReloadWaiter: Sendable {
    var send: @Sendable (String) -> Void
    var requestId: JSONValue
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
    /// `xcmcptap_reload` requests waiting for the next boot to settle.
    var reloadWaiters: [ReloadWaiter] = []
    /// True from the moment we first transition into `.failed` until we
    /// next reach `.ready`. Drives the recovery `tools/list_changed`
    /// broadcast: if a previous failure was visible to clients, the
    /// transition back to `.ready` must tell them to refetch tools.
    var hasObservedFailure: Bool = false
  }

  /// Computed synchronously under the state mutex by `prepareOutgoing`.
  /// Forwards to the bridge happen asynchronously AFTER the mutex is
  /// released, but the state mutations (id allocation, mapping
  /// registration, envelope rewriting) are already committed — so a
  /// follow-up message can safely look up what was just registered.
  ///
  /// `triggerReloadBoot` carries no payload — the reload waiter has
  /// already been parked in `state.reloadWaiters` under the lock. The
  /// caller spawns a `boot()` Task that will eventually drain the
  /// waiter with a success or failure tool result.
  private enum Action {
    case none
    case replyToClient(@Sendable (String) -> Void, String)
    case forwardToBridge(Data)
    case triggerReloadBoot
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
    serviceName: String,
    clientName: String,
    makeConnection: @Sendable @escaping () -> MCPConnection,
    healthPingInterval: Duration = .seconds(30),
    healthPingTimeout: Duration = .seconds(10),
    sleeper: @escaping Sleeper = { duration in
      try? await Task.sleep(for: duration)
    },
  ) {
    self.log = Logger(subsystem: serviceName, category: "router")
    self.clientName = clientName
    self.makeConnection = makeConnection
    self.healthPingInterval = healthPingInterval
    self.healthPingTimeout = healthPingTimeout
    self.sleeper = sleeper
  }

  /// Backward-compatible initializer for tests that own a single
  /// MCPConnection and never exercise respawn. Any recovery path will
  /// re-use the same dead connection, which is fine for tests that
  /// stay in `.ready`.
  public convenience init(
    serviceName: String,
    clientName: String,
    connection: MCPConnection,
  ) {
    let captured = connection
    self.init(serviceName: serviceName, clientName: clientName, makeConnection: { captured })
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
    let action = state.withLock { s -> Action in
      if s.isShutdown { return .none }
      switch s.bridge {
      case .booting:
        s.pending.append((clientID, content))
        return .none
      case .ready, .failed:
        return Self.prepareOutgoing(from: clientID, content: content, state: &s)
      }
    }
    perform(action)
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
  public func markBridgeUnavailable(reason: String) {
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
        markBridgeUnavailable(
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
          clientName: clientName,
          clientVersion: "1.0",
        ),
      )
      try await connection.notify(method: "notifications/initialized")

      // Flush buffered messages synchronously under the lock so ordering
      // between two buffered messages from the same client is preserved
      // — e.g. a cancel following its tools/call sees the just-registered
      // mapping.
      let (
        actions, reloadReplies, listChangedRecipients, notify, flushedCount,
      ) = state.withLock { s -> (
        [Action],
        [(send: @Sendable (String) -> Void, line: String)],
        [@Sendable (String) -> Void],
        (@Sendable (BridgeStatus) -> Void)?,
        Int
      ) in
        s.bridge = .ready(cachedInit: initResponse)
        let flushed = s.pending
        s.pending = []
        let acts = flushed.map { entry in
          Self.prepareOutgoing(from: entry.client, content: entry.content, state: &s)
        }
        // Drain reload waiters with success results.
        let waiters = s.reloadWaiters
        s.reloadWaiters = []
        let replies: [(@Sendable (String) -> Void, String)] = waiters
          .compactMap { w in
            guard let line = Self.encodeReloadSuccessResult(id: w.requestId) else { return nil }
            return (w.send, line)
          }
        // If the previous lifecycle saw a failure that clients had a
        // chance to observe, broadcast list_changed so they refetch the
        // real tool list. The first ever `.ready` (no prior failure)
        // does not broadcast — clients have nothing stale to refresh.
        let recipients: [@Sendable (String) -> Void] = s.hasObservedFailure
          ? Array(s.clients.values.map(\.send))
          : []
        s.hasObservedFailure = false
        return (acts, replies, recipients, s.onBridgeStateChanged, flushed.count)
      }
      log.notice("bridge ready (flushed \(flushedCount, privacy: .public) buffered)")
      for action in actions {
        perform(action)
      }
      for reply in reloadReplies {
        reply.send(reply.line)
      }
      for send in listChangedRecipients {
        send(Self.toolsListChangedNotification)
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
  /// — in-flight mapped requests, pending queue, and `xcmcptap_reload`
  /// waiters. Idempotent: a second call after state is already `.failed`
  /// is a no-op, so boot-failure and passthrough-closure can race
  /// safely. The old connection is terminated asynchronously so the
  /// mutex stays short.
  ///
  /// Broadcasts `notifications/tools/list_changed` to all clients when
  /// transitioning from `.ready` so they refetch and see fallback tools
  /// instead of their stale real-tools cache.
  private func markBridgeFailed(reason: String, failingConnection: MCPConnection) {
    let (
      actions, reloadReplies, listChangedRecipients, oldConnection, notify,
    ) = state.withLock { s -> (
      [Action],
      [(send: @Sendable (String) -> Void, line: String)],
      [@Sendable (String) -> Void],
      MCPConnection?,
      (@Sendable (BridgeStatus) -> Void)?
    ) in
      // Only transition if the failing connection is still current —
      // stale drains from a previous-generation bridge must be ignored.
      guard s.currentConnection === failingConnection else { return ([], [], [], nil, nil) }
      let wasReady: Bool
      switch s.bridge {
      case .failed: return ([], [], [], nil, nil)
      case .ready: wasReady = true
      case .booting: wasReady = false
      }
      s.bridge = .failed(reason: reason)
      s.hasObservedFailure = true
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
      // fallback responses (for requests) or drops (for notifications).
      let queued = s.pending
      s.pending = []
      for entry in queued {
        out.append(Self.prepareOutgoing(from: entry.client, content: entry.content, state: &s))
      }

      // Drain reload waiters: this boot failed (or the bridge crashed
      // mid-reload), so each reload caller gets a fresh failure result.
      let waiters = s.reloadWaiters
      s.reloadWaiters = []
      let replies: [(@Sendable (String) -> Void, String)] = waiters
        .compactMap { w in
          guard let line = Self.encodeReloadFailureResult(
            id: w.requestId, reason: reason,
          ) else { return nil }
          return (w.send, line)
        }

      // Only broadcast list_changed if clients had real tools cached.
      let recipients: [@Sendable (String) -> Void] = wasReady
        ? Array(s.clients.values.map(\.send))
        : []

      return (out, replies, recipients, old, s.onBridgeStateChanged)
    }
    if oldConnection != nil {
      log.error("bridge failed: \(reason, privacy: .public)")
    }
    for action in actions {
      perform(action)
    }
    for reply in reloadReplies {
      reply.send(reply.line)
    }
    for send in listChangedRecipients {
      send(Self.toolsListChangedNotification)
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
    case .triggerReloadBoot:
      let notify = state.withLock { $0.onBridgeStateChanged }
      notify?(.booting)
      log.notice("bridge respawn triggered by xcmcptap_reload")
      Task { await self.boot() }
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
      case .failed:
        guard let id = envelope.id,
              let line = encodeFallbackInitialize(id: id, request: envelope) else { return .none }
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

    case "tools/list":
      if case .failed = s.bridge {
        guard let slot = s.clients[clientID], let id = envelope.id,
              let line = encodeFallbackToolsList(id: id) else { return .none }
        return .replyToClient(slot.send, line)
      }
      // Live bridge → fall through to default forward path.

    case "tools/call":
      if case let .failed(reason) = s.bridge {
        return prepareFallbackToolCall(
          envelope: envelope, clientID: clientID, reason: reason, state: &s,
        )
      }
      // Live bridge → fall through to default forward path.

    default:
      break
    }

    // Default path: a request (has id) or any other client notification.
    // Dead bridge → JSON-RPC -32601 for requests, silent drops for
    // notifications. Live bridge → rewrite id + progressToken, forward.
    if case .failed = s.bridge {
      guard let slot = s.clients[clientID], let id = envelope.id else {
        return .none // notification: drop
      }
      let methodName = envelope.method ?? "<missing>"
      guard let line = encodeMethodNotFound(id: id, method: methodName) else { return .none }
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

  /// Routes a `tools/call` while the bridge is `.failed`. Dispatches to
  /// the proxy's two built-in fallback tools and surfaces an MCP-shaped
  /// `isError: true` result for any other tool name.
  private static func prepareFallbackToolCall(
    envelope: RPCEnvelope,
    clientID: UUID,
    reason: String,
    state s: inout State,
  ) -> Action {
    guard let slot = s.clients[clientID], let id = envelope.id else {
      return .none // tool calls without an id are nonsense; drop.
    }
    let toolName: String? = if case let .object(params)? = envelope.rest["params"],
                               case let .string(name)? = params["name"] { name } else { nil }
    switch toolName {
    case "xcmcptap_status":
      guard let line = encodeStatusToolResult(id: id, reason: reason) else { return .none }
      return .replyToClient(slot.send, line)
    case "xcmcptap_reload":
      // Park the waiter, transition state, ask perform() to spawn boot.
      s.bridge = .booting
      s.reloadWaiters.append(ReloadWaiter(send: slot.send, requestId: id))
      return .triggerReloadBoot
    default:
      let displayName = toolName ?? "<missing>"
      guard let line = encodeUnknownToolResult(id: id, name: displayName) else { return .none }
      return .replyToClient(slot.send, line)
    }
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
    return encodeLine(envelope)
  }

  /// Encodes a JSON-RPC `-32601` (method not found) reply. Used in
  /// fallback mode for request methods we don't synthesize a response
  /// for (everything outside `initialize` / `tools/list` / `tools/call`).
  private static func encodeMethodNotFound(id: JSONValue, method: String) -> String? {
    let envelope = RPCEnvelope(
      id: id,
      rest: [
        "jsonrpc": .string("2.0"),
        "error": .object([
          "code": .number(Decimal(-32601)),
          "message": .string(
            "Method not available: \(method). Xcode MCP bridge is unavailable.",
          ),
        ]),
      ],
    )
    return encodeLine(envelope)
  }

  /// Synthesizes the `initialize` response served while the bridge is
  /// `.failed`. Echoes back the client's requested protocolVersion so
  /// any host accepting that version proceeds, and advertises
  /// `tools.listChanged: true` so the host re-fetches `tools/list` once
  /// we emit a recovery notification.
  private static func encodeFallbackInitialize(
    id: JSONValue, request: RPCEnvelope,
  ) -> String? {
    var protocolVersion = MCPProtocol.version
    if case let .object(params)? = request.rest["params"],
       case let .string(v)? = params["protocolVersion"]
    {
      protocolVersion = v
    }
    let envelope = RPCEnvelope(
      id: id,
      rest: [
        "jsonrpc": .string("2.0"),
        "result": .object([
          "protocolVersion": .string(protocolVersion),
          "capabilities": .object([
            "tools": .object(["listChanged": .bool(true)]),
          ]),
          "serverInfo": .object([
            "name": .string("xcmcptap"),
            "version": .string("fallback"),
          ]),
          "instructions": .string(
            "Xcode MCP bridge is currently unavailable. "
              + "Use xcmcptap_status to inspect the failure or "
              + "xcmcptap_reload to attempt recovery.",
          ),
        ]),
      ],
    )
    return encodeLine(envelope)
  }

  /// The fallback `tools/list` response — exactly the proxy's two
  /// built-in meta-tools, nothing else.
  private static func encodeFallbackToolsList(id: JSONValue) -> String? {
    let envelope = RPCEnvelope(
      id: id,
      rest: [
        "jsonrpc": .string("2.0"),
        "result": .object([
          "tools": .array([
            .object([
              "name": .string("xcmcptap_status"),
              "description": .string(
                "Returns the current state of the Xcode MCP bridge "
                  + "(running, failed, reason). Read-only.",
              ),
              "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
              ]),
            ]),
            .object([
              "name": .string("xcmcptap_reload"),
              "description": .string(
                "Attempts to restart the Xcode MCP bridge. Call this "
                  + "after launching Xcode to make the real Xcode tools "
                  + "available again.",
              ),
              "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
              ]),
            ]),
          ]),
        ]),
      ],
    )
    return encodeLine(envelope)
  }

  /// `xcmcptap_status` tool result. Plain text, no `isError`. The text
  /// must contain the actual mcpbridge failure reason — agents and
  /// users need that string to know what went wrong.
  private static func encodeStatusToolResult(id: JSONValue, reason: String) -> String? {
    let body = "Xcode MCP bridge: failed\nReason: \(reason)"
    return encodeToolTextResult(id: id, text: body, isError: false)
  }

  /// `xcmcptap_reload` failure result. `isError: true` per MCP
  /// convention so hosts surface it as a tool error rather than a
  /// successful response. The reason is the freshly captured stderr
  /// from the boot attempt that just failed.
  private static func encodeReloadFailureResult(id: JSONValue, reason: String) -> String? {
    let body = "Reload failed.\nReason: \(reason)"
    return encodeToolTextResult(id: id, text: body, isError: true)
  }

  /// `xcmcptap_reload` success result. Plain text, no `isError`.
  /// The accompanying `notifications/tools/list_changed` is emitted
  /// separately by the boot success path.
  private static func encodeReloadSuccessResult(id: JSONValue) -> String? {
    let body = "Xcode MCP bridge restored. The host will refresh tools/list."
    return encodeToolTextResult(id: id, text: body, isError: false)
  }

  /// Result for a `tools/call` whose tool name isn't one of the
  /// fallback meta-tools. `isError: true` so the host treats it as a
  /// tool error rather than a successful answer.
  private static func encodeUnknownToolResult(id: JSONValue, name: String) -> String? {
    let body = "Tool '\(name)' is not available — Xcode MCP bridge is unavailable. "
      + "Use xcmcptap_status to inspect or xcmcptap_reload to attempt recovery."
    return encodeToolTextResult(id: id, text: body, isError: true)
  }

  private static func encodeToolTextResult(
    id: JSONValue, text: String, isError: Bool,
  ) -> String? {
    var result: [String: JSONValue] = [
      "content": .array([
        .object([
          "type": .string("text"),
          "text": .string(text),
        ]),
      ]),
    ]
    if isError { result["isError"] = .bool(true) }
    let envelope = RPCEnvelope(
      id: id,
      rest: [
        "jsonrpc": .string("2.0"),
        "result": .object(result),
      ],
    )
    return encodeLine(envelope)
  }

  private static func encodeLine(_ envelope: RPCEnvelope) -> String? {
    guard let data = try? JSONEncoder().encode(envelope),
          let line = String(data: data, encoding: .utf8) else { return nil }
    return line
  }

  private static let toolsListChangedNotification =
    #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#

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
