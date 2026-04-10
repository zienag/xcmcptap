import Testing
import XcodeMCPTapServiceCore
import XcodeMCPTapShared

@Suite(.serialized)
struct MCPBridgeHandshakeTests {

  @Test func handshakeWithMCPBridge() async throws {
    let h = RouterHarness.mcpbridge()
    defer { h.terminate() }

    let envelope = try await h.handshake()

    #expect(envelope.id == 1)
    guard case .object(let result)? = envelope.rest["result"],
          case .object(let serverInfo)? = result["serverInfo"] else {
      Issue.record("Expected result.serverInfo, got: \(envelope)")
      return
    }
    #expect(serverInfo["name"] == "xcode-tools")
  }
}
