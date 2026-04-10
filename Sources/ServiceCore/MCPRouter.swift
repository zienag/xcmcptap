import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import struct Foundation.Data
import Synchronization
import XcodeMCPTapShared

public final class MCPRouter: Sendable {
  private let connection: MCPConnection
  private let state = Mutex(State())

  private struct State: Sendable {
    var cachedInitResponse: RPCEnvelope?
    var pendingClientMessages: [String] = []
    var ready: Bool = false
    var sendToClient: (@Sendable (String) -> Void)?
    var onToolsDiscovered: (@Sendable ([ToolInfo]) -> Void)?
  }

  public var sendToClient: (@Sendable (String) -> Void)? {
    get { state.withLock { $0.sendToClient } }
    set { state.withLock { $0.sendToClient = newValue } }
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

  public func handleClientMessage(_ content: String) {
    let shouldBuffer = state.withLock { s -> Bool in
      if !s.ready {
        s.pendingClientMessages.append(content)
        return true
      }
      return false
    }
    if !shouldBuffer {
      Task { await self.routeClientMessage(content) }
    }
  }

  // MARK: - Private

  private func boot() async {
    await connection.start()
    do {
      let initResponse = try await connection.request(
        method: "initialize",
        params: .object([
          "protocolVersion": .string(MCPProtocol.version),
          "capabilities": .object([:]),
          "clientInfo": .object([
            "name": "XcodeMCPTap",
            "version": "1.0",
          ]),
        ])
      )
      state.withLock { $0.cachedInitResponse = initResponse }
      try await connection.notify(method: "initialized")
    } catch {
      return
    }

    let pending = state.withLock { s -> [String] in
      s.ready = true
      let p = s.pendingClientMessages
      s.pendingClientMessages = []
      return p
    }

    for msg in pending {
      await routeClientMessage(msg)
    }

    // Background tool discovery — not on the critical path.
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
      let handler = state.withLock { $0.sendToClient }
      handler?(str)
    }
  }

  private func routeClientMessage(_ content: String) async {
    guard let envelope = try? JSONDecoder().decode(
      RPCEnvelope.self, from: Data(content.utf8)
    ) else {
      try? await connection.forward(Data(content.utf8))
      return
    }

    switch envelope.method {
    case "initialize":
      let (cached, handler) = state.withLock { ($0.cachedInitResponse, $0.sendToClient) }
      if var response = cached {
        response.id = envelope.id
        if let data = try? JSONEncoder().encode(response),
           let line = String(data: data, encoding: .utf8) {
          handler?(line)
        }
      }

    case "initialized":
      break

    default:
      try? await connection.forward(Data(content.utf8))
    }
  }
}
