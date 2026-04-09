import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import struct Foundation.Data
import Synchronization
import XcodeMCPTapShared

public final class MCPRouter: Sendable {
  private let bridge: BridgeProcess
  private let state = Mutex(State())

  private struct State: Sendable {
    var phase: Phase = .initializing
    var cachedInitResponse: RPCEnvelope?
    var pendingClientMessages: [String] = []
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

  private enum Phase: Sendable {
    case initializing
    case fetchingTools
    case ready
  }

  public init(bridge: BridgeProcess) {
    self.bridge = bridge
  }

  public func start() {
    bridge.onOutput = { [self] line in
      handleBridgeMessage(line)
    }

    bridge.start()

    let initEnvelope = RPCEnvelope(
      id: "proxy-init",
      method: "initialize",
      rest: [
        "jsonrpc": "2.0",
        "params": [
          "protocolVersion": "2024-11-05",
          "capabilities": [:],
          "clientInfo": [
            "name": "XcodeMCPTap",
            "version": "1.0",
          ],
        ],
      ]
    )

    guard let data = try? JSONEncoder().encode(initEnvelope) else { return }
    bridge.write(data)
  }

  public func handleClientMessage(_ content: String) {
    let shouldBuffer = state.withLock { s -> Bool in
      if s.phase != .ready {
        s.pendingClientMessages.append(content)
        return true
      }
      return false
    }
    if !shouldBuffer {
      routeClientMessage(content)
    }
  }

  // MARK: - Private

  private func routeClientMessage(_ content: String) {
    guard let envelope = try? JSONDecoder().decode(
      RPCEnvelope.self, from: Data(content.utf8)
    ) else {
      bridge.write(Data(content.utf8))
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
      bridge.write(Data(content.utf8))
    }
  }

  private func handleBridgeMessage(_ content: String) {
    let phase = state.withLock { $0.phase }

    switch phase {
    case .initializing:
      handleInitResponse(content)
    case .fetchingTools:
      handleToolsResponse(content)
    case .ready:
      let handler = state.withLock { $0.sendToClient }
      handler?(content)
    }
  }

  private func handleInitResponse(_ content: String) {
    if let envelope = try? JSONDecoder().decode(
      RPCEnvelope.self, from: Data(content.utf8)
    ) {
      state.withLock { $0.cachedInitResponse = envelope }
    }

    let initializedEnvelope = RPCEnvelope(
      method: "initialized",
      rest: ["jsonrpc": "2.0"]
    )
    if let data = try? JSONEncoder().encode(initializedEnvelope) {
      bridge.write(data)
    }

    state.withLock { $0.phase = .fetchingTools }

    let toolsEnvelope = RPCEnvelope(
      id: "proxy-tools",
      method: "tools/list",
      rest: [
        "jsonrpc": "2.0",
        "params": [:],
      ]
    )
    if let data = try? JSONEncoder().encode(toolsEnvelope) {
      bridge.write(data)
    }
  }

  private func handleToolsResponse(_ content: String) {
    if let envelope = try? JSONDecoder().decode(
      RPCEnvelope.self, from: Data(content.utf8)
    ),
      case .object(let result)? = envelope.rest["result"],
      case .array(let tools)? = result["tools"] {
      let toolInfos = tools.compactMap { toolValue -> ToolInfo? in
        guard case .object(let tool) = toolValue,
              case .string(let name)? = tool["name"] else { return nil }
        let description: String
        if case .string(let d)? = tool["description"] {
          description = d
        } else {
          description = ""
        }
        return ToolInfo(name: name, description: description)
      }
      let handler = state.withLock { $0.onToolsDiscovered }
      handler?(toolInfos)
    }

    let pending = state.withLock { s -> [String] in
      s.phase = .ready
      let p = s.pendingClientMessages
      s.pendingClientMessages = []
      return p
    }

    for msg in pending {
      routeClientMessage(msg)
    }
  }
}
