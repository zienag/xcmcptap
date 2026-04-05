import class Foundation.JSONEncoder
import class Foundation.JSONSerialization
import struct Foundation.Data
import Synchronization
import XcodeMCPTapShared

public final class MCPRouter: @unchecked Sendable {
  public var sendToClient: (@Sendable (String) -> Void)?
  public var onToolsDiscovered: (@Sendable ([ToolInfo]) -> Void)?

  private let bridge: BridgeProcess
  private let state = Mutex(State())

  private struct State: Sendable {
    var phase: Phase = .initializing
    var cachedInitResult: Data = Data()
    var pendingClientMessages: [String] = []
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

    let initData = try! JSONEncoder().encode(
      RPCRequest(
        id: "proxy-init",
        method: "initialize",
        params: InitializeParams(
          protocolVersion: "2024-11-05",
          capabilities: .init(),
          clientInfo: .init(name: "XcodeMCPTap", version: "1.0")
        )
      )
    )

    bridge.write(initData)
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
    guard let msg = RPCMessage(content) else {
      bridge.write(Data(content.utf8))
      return
    }

    switch msg.parsed.method {
    case "initialize":
      let resultData = state.withLock { $0.cachedInitResult }
      var response: [String: Any] = [
        "jsonrpc": "2.0",
        "result": (try? JSONSerialization.jsonObject(with: resultData)) as Any,
      ]
      if let id = msg.parsed.id { response["id"] = id.jsonValue }
      if let data = try? JSONSerialization.data(withJSONObject: response),
         let line = String(data: data, encoding: .utf8) {
        sendToClient?(line)
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
      sendToClient?(content)
    }
  }

  private func handleInitResponse(_ content: String) {
    if let msg = RPCMessage(content),
       let json = try? JSONSerialization.jsonObject(with: msg.raw) as? [String: Any],
       let result = json["result"],
       let resultData = try? JSONSerialization.data(withJSONObject: result) {
      state.withLock { $0.cachedInitResult = resultData }
    }

    bridge.write(try! JSONEncoder().encode(RPCNotification(method: "initialized")))

    state.withLock { $0.phase = .fetchingTools }

    bridge.write(try! JSONEncoder().encode(
      RPCRequest(
        id: "proxy-tools",
        method: "tools/list",
        params: EmptyParams()
      )
    ))
  }

  private func handleToolsResponse(_ content: String) {
    if let msg = RPCMessage(content),
       let json = try? JSONSerialization.jsonObject(with: msg.raw) as? [String: Any],
       let result = json["result"] as? [String: Any],
       let tools = result["tools"] as? [[String: Any]] {
      let toolInfos = tools.compactMap { tool -> ToolInfo? in
        guard let name = tool["name"] as? String else { return nil }
        let description = tool["description"] as? String ?? ""
        return ToolInfo(name: name, description: description)
      }
      onToolsDiscovered?(toolInfos)
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

// MARK: - JSON-RPC Encodable Types

private struct RPCRequest<Params: Encodable>: Encodable {
  var jsonrpc = "2.0"
  var id: String?
  var method: String
  var params: Params
}

private struct RPCNotification: Encodable {
  var jsonrpc = "2.0"
  var method: String
}

private struct EmptyParams: Encodable {}

private struct InitializeParams: Encodable {
  var protocolVersion: String
  var capabilities: EmptyObject
  var clientInfo: ClientInfo

  struct EmptyObject: Encodable {}

  struct ClientInfo: Encodable {
    var name: String
    var version: String
  }
}
