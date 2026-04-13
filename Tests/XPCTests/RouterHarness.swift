import class Foundation.JSONDecoder
import struct Foundation.Data
import struct Foundation.UUID
import System
import XcodeMCPTapService
import XcodeMCPTapShared

/// Convenience wrapper around MCPRouter + MCPConnection + ResponseCollector
/// for tests. Owns the connection lifetime; call `terminate()` when done.
final class RouterHarness {
  let connection: MCPConnection
  let router: MCPRouter
  let collector: ResponseCollector
  let clientID: UUID

  convenience init(exec: String, _ args: String...) {
    self.init(connection: MCPConnection(exec: exec, args: args))
  }

  private init(connection: MCPConnection) {
    self.connection = connection
    self.router = MCPRouter(connection: connection)
    self.collector = ResponseCollector()
    self.clientID = router.registerClient { [collector] line in
      collector.continuation.yield(line)
    }
    router.start()
  }

  static func mock(bridge path: String) -> RouterHarness {
    RouterHarness(exec: "/usr/bin/python3", "-u", path)
  }

  func send(_ json: String) {
    router.handleClientMessage(from: clientID, json)
  }

  func sendInitialize(id: Int = 1) {
    send(
      #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{"protocolVersion":"\#(MCPProtocol.version)","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#
    )
  }

  func sendInitialized() {
    send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
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

  func terminate() async {
    await connection.terminate()
  }
}

/// Absolute paths to test helper scripts under `scripts/`, resolved
/// relative to the test file location.
enum TestScripts {
  static func path(_ name: String, from file: StaticString = #filePath) -> String {
    var p = FilePath("\(file)")
    p.removeLastComponent()
    p.removeLastComponent()
    p.removeLastComponent()
    p.append("scripts")
    p.append(name)
    return p.string
  }
}

enum MockBridge {
  static func path(from file: StaticString = #filePath) -> String {
    TestScripts.path("mock-mcpbridge.py", from: file)
  }
}
