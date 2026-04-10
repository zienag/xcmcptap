import class Foundation.JSONDecoder
import struct Foundation.Data
import System
import XcodeMCPTapServiceCore
import XcodeMCPTapShared

/// Convenience wrapper around MCPRouter + MCPConnection + BridgeProcess + ResponseCollector
/// for tests. Owns the bridge lifetime; call `terminate()` when done.
final class RouterHarness {
  let bridge: BridgeProcess
  let router: MCPRouter
  let collector: ResponseCollector

  init(bridge: BridgeProcess) {
    self.bridge = bridge
    self.router = MCPRouter(connection: MCPConnection(bridge: bridge))
    self.collector = ResponseCollector()
    router.sendToClient = { [collector] line in
      collector.continuation.yield(line)
    }
    router.start()
  }

  static func fake(server path: String) -> RouterHarness {
    RouterHarness(bridge: BridgeProcess(
      executable: "/usr/bin/python3",
      arguments: ["-u", path]
    ))
  }

  static func mcpbridge() -> RouterHarness {
    RouterHarness(bridge: BridgeProcess())
  }

  func send(_ json: String) {
    router.handleClientMessage(json)
  }

  func sendInitialize(id: Int = 1) {
    send(
      #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{"protocolVersion":"\#(MCPProtocol.version)","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#
    )
  }

  func sendInitialized() {
    send(#"{"jsonrpc":"2.0","method":"initialized"}"#)
  }

  /// Sends a client initialize and awaits the replayed cached response.
  func handshake(id: Int = 1) async throws -> RPCEnvelope {
    sendInitialize(id: id)
    return try await nextResponse()
  }

  func nextResponse() async throws -> RPCEnvelope {
    let line = try await collector.nextResponse()
    return try JSONDecoder().decode(RPCEnvelope.self, from: Data(line.utf8))
  }

  func collect(count: Int) async throws -> [RPCEnvelope] {
    let lines = try await collector.collect(count: count)
    return try lines.map {
      try JSONDecoder().decode(RPCEnvelope.self, from: Data($0.utf8))
    }
  }

  func terminate() {
    bridge.terminate()
  }
}

/// Absolute path to the fake MCP server python script, resolved relative to
/// the test file location.
enum FakeMCPServer {
  static func path(from file: StaticString = #filePath) -> String {
    var p = FilePath("\(file)")
    p.removeLastComponent()
    p.removeLastComponent()
    p.removeLastComponent()
    p.append("fake-mcp-server.py")
    return p.string
  }
}
