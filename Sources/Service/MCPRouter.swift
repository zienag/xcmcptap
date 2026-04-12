import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import class Foundation.NSDecimalNumber
import struct Foundation.Data
import struct Foundation.Decimal
import struct Foundation.UUID
import Synchronization
import XcodeMCPTapShared

public final class MCPRouter: Sendable {
  private let connection: MCPConnection
  private let state = Mutex(State())

  private struct ClientSlot: Sendable {
    var send: @Sendable (String) -> Void
  }

  private struct Mapping: Sendable {
    var client: UUID
    var original: JSONValue
  }

  private struct State: Sendable {
    var cachedInitResponse: RPCEnvelope?
    var bridgeReady: Bool = false
    var pending: [(client: UUID, content: String)] = []
    var clients: [UUID: ClientSlot] = [:]
    /// bridge-facing id (canonical string) → origin client + client's id
    var idMap: [String: Mapping] = [:]
    /// bridge-facing progressToken (canonical string) → origin client + token
    var progressMap: [String: Mapping] = [:]
    var nextBridgeID: Int = 1
    var onToolsDiscovered: (@Sendable ([ToolInfo]) -> Void)?
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

  public init(connection: MCPConnection) {
    self.connection = connection
  }

  public func start() {
    Task { await self.boot() }
    Task { await self.drainPassthrough() }
  }

  /// Register a connected client with its send callback. Use the returned
  /// id (or a UUID you already own) when calling `handleClientMessage`.
  public func registerClient(
    id: UUID = UUID(),
    send: @escaping @Sendable (String) -> Void
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
      if !s.bridgeReady {
        s.pending.append((clientID, content))
        return .none
      }
      return Self.prepareOutgoing(from: clientID, content: content, state: &s)
    }
    perform(action)
  }

  // MARK: - Private

  private func boot() async {
    await connection.start()
    do {
      let initResponse = try await connection.request(
        method: "initialize",
        params: MCPProtocol.initializeParams(
          clientName: "XcodeMCPTap",
          clientVersion: "1.0"
        )
      )
      state.withLock { $0.cachedInitResponse = initResponse }
      try await connection.notify(method: "notifications/initialized")
    } catch {
      return
    }

    // Flush buffered messages synchronously under the lock so ordering
    // between two buffered messages from the same client is preserved
    // — e.g. a cancel following its tools/call sees the just-registered
    // mapping.
    let actions = state.withLock { s -> [Action] in
      s.bridgeReady = true
      let flushed = s.pending
      s.pending = []
      return flushed.map { entry in
        Self.prepareOutgoing(from: entry.client, content: entry.content, state: &s)
      }
    }
    for action in actions { perform(action) }

    Task {
      guard let response = try? await connection.request(
        method: "tools/list",
        params: .object([:])
      ) else { return }
      guard case .object(let result)? = response.rest["result"],
            case .array(let tools)? = result["tools"] else { return }
      let infos = tools.compactMap { t -> ToolInfo? in
        guard case .object(let o) = t, case .string(let name)? = o["name"] else { return nil }
        let description: String = if case .string(let d)? = o["description"] { d } else { "" }
        return ToolInfo(name: name, description: description)
      }
      let handler = state.withLock { $0.onToolsDiscovered }
      handler?(infos)
    }
  }

  private func drainPassthrough() async {
    for await line in connection.passthrough {
      guard let str = String(bytes: line, encoding: .utf8) else { continue }
      deliverFromBridge(str)
    }
  }

  private func deliverFromBridge(_ raw: String) {
    guard var envelope = try? JSONDecoder().decode(
      RPCEnvelope.self, from: Data(raw.utf8)
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
           let line = String(data: data, encoding: .utf8) {
          resolved.send(line)
        }
      }
      return
    }

    // Progress notification: tied to an originally-allocated bridge token.
    if envelope.method == "notifications/progress",
       case .object(var params)? = envelope.rest["params"],
       let token = params["progressToken"],
       let key = Self.idKey(token) {
      let resolved = state.withLock { s -> (send: @Sendable (String) -> Void, original: JSONValue)? in
        guard let mapping = s.progressMap[key] else { return nil }
        guard let slot = s.clients[mapping.client] else { return nil }
        return (slot.send, mapping.original)
      }
      if let resolved {
        params["progressToken"] = resolved.original
        envelope.rest["params"] = .object(params)
        if let data = try? JSONEncoder().encode(envelope),
           let line = String(data: data, encoding: .utf8) {
          resolved.send(line)
        }
      }
      return
    }

    // Uncorrelated server-initiated notifications (tools/list_changed, etc.)
    // are broadcast to every connected client.
    let recipients = state.withLock { s in s.clients.values.map(\.send) }
    for send in recipients { send(raw) }
  }

  private func perform(_ action: Action) {
    switch action {
    case .none:
      return
    case .replyToClient(let send, let line):
      send(line)
    case .forwardToBridge(let data):
      Task { try? await self.connection.forward(data) }
    }
  }

  /// Everything synchronous about routing a client message — envelope
  /// parsing, bridge-id allocation, mapping registration, and rewriting.
  /// Runs under the state mutex so two rapid messages from the same
  /// client (e.g. tools/call followed immediately by
  /// notifications/cancelled) are serialized and the cancel reliably
  /// observes the mapping the tools/call just installed.
  private static func prepareOutgoing(
    from clientID: UUID,
    content: String,
    state s: inout State
  ) -> Action {
    guard let envelope = try? JSONDecoder().decode(
      RPCEnvelope.self, from: Data(content.utf8)
    ) else {
      return .forwardToBridge(Data(content.utf8))
    }

    switch envelope.method {
    case "initialize":
      guard var response = s.cachedInitResponse, let slot = s.clients[clientID] else {
        return .none
      }
      response.id = envelope.id
      guard let data = try? JSONEncoder().encode(response),
            let line = String(data: data, encoding: .utf8) else { return .none }
      return .replyToClient(slot.send, line)

    case "notifications/initialized":
      return .none

    case "notifications/cancelled":
      var rewritten = envelope
      if case .object(var params)? = envelope.rest["params"],
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

    // Default path: rewrite request id and any _meta.progressToken.
    var rewritten = envelope
    if let originalId = envelope.id {
      let bridgeId = s.nextBridgeID
      s.nextBridgeID += 1
      s.idMap[String(bridgeId)] = Mapping(client: clientID, original: originalId)
      rewritten.id = .number(Decimal(bridgeId))
    }

    if case .object(var params)? = envelope.rest["params"] {
      if case .object(var meta)? = params["_meta"],
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

  /// Canonicalizes a JSON-RPC id or progress token to a string key so that
  /// integer `N` and string `"N"` collapse to the same map entry — real
  /// mcpbridge sometimes stringifies progressTokens on the way back.
  private static func idKey(_ value: JSONValue) -> String? {
    switch value {
    case .number(let n):
      return String(NSDecimalNumber(decimal: n).int64Value)
    case .string(let s):
      return s
    default:
      return nil
    }
  }
}
