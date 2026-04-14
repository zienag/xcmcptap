import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

@Suite(.serialized)
struct MCPBridgeHandshakeTests {
  @Test func handshakeWithMCPBridge() async throws {
    let connection = MCPConnection(exec: MockBridge.path())
    await connection.start()
    defer { Task { await connection.terminate() } }

    let response = try await connection.request(
      method: "initialize",
      params: MCPProtocol.initializeParams(clientName: "test", clientVersion: "1.0"),
    )
    let result = try response.decodeResult(as: InitializeResult.self)
    #expect(result.serverInfo.name == "xcode-tools")
  }

  @Test func listToolsFromMCPBridge() async throws {
    let connection = MCPConnection(exec: MockBridge.path())
    await connection.start()
    defer { Task { await connection.terminate() } }

    _ = try await connection.request(
      method: "initialize",
      params: MCPProtocol.initializeParams(clientName: "test", clientVersion: "1.0"),
    )
    try await connection.notify(method: "notifications/initialized")

    let response = try await connection.request(
      method: "tools/list",
      params: .object([:]),
    )
    let result = try response.decodeResult(as: ListToolsResult.self)
    #expect(!result.tools.isEmpty)
    #expect(result.tools.contains { $0.name == "BuildProject" })
  }
}
