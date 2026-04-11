import class Foundation.JSONDecoder
import struct Foundation.Data
import struct Foundation.Decimal
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

@Suite(.serialized)
struct MCPProxyTests {
  static let fakeMCPServer = FakeMCPServer.path()

  private func makeHarness() -> RouterHarness {
    .fake(server: Self.fakeMCPServer)
  }

  // MARK: - Tests

  @Test func initializeHandshake() async throws {
    let h = makeHarness()
    let conn = h.connection
    defer { Task { await conn.terminate() } }

    let envelope = try await h.handshake(id: 42)

    #expect(envelope.id == 42)
    #expect(envelope.rest["jsonrpc"] == "2.0")

    let result = try #require(envelope.rest["result"])
    guard case .object(let resultDict) = result else {
      Issue.record("result should be an object")
      return
    }
    guard case .object(let serverInfo)? = resultDict["serverInfo"] else {
      Issue.record("serverInfo should be an object")
      return
    }
    #expect(serverInfo["name"] == "fake-mcp-server")
    #expect(resultDict["protocolVersion"] == .string(MCPProtocol.version))
  }

  @Test func toolsList() async throws {
    let h = makeHarness()
    let conn = h.connection
    defer { Task { await conn.terminate() } }

    _ = try await h.handshake()
    h.sendInitialized()
    h.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)

    let envelope = try await h.nextResponse()
    #expect(envelope.id == 2)
    guard case .object(let result)? = envelope.rest["result"],
          case .array(let tools)? = result["tools"] else {
      Issue.record("Expected result.tools array")
      return
    }
    let toolNames = tools.compactMap { tool -> String? in
      guard case .object(let t) = tool, case .string(let name)? = t["name"] else { return nil }
      return name
    }
    #expect(toolNames.contains("echo"))
    #expect(toolNames.contains("greet"))
  }

  @Test func toolsCall() async throws {
    let h = makeHarness()
    let conn = h.connection
    defer { Task { await conn.terminate() } }

    _ = try await h.handshake()
    h.sendInitialized()
    h.send(
      #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello world"}}}"#
    )

    let envelope = try await h.nextResponse()
    #expect(envelope.id == 3)
    guard case .object(let result)? = envelope.rest["result"],
          case .array(let content)? = result["content"],
          case .object(let first)? = content.first,
          case .string(let text)? = first["text"] else {
      Issue.record("Expected result.content[0].text")
      return
    }
    let echoed = try JSONDecoder().decode(RPCEnvelope.self, from: Data(text.utf8))
    #expect(echoed.rest["tool"] == "echo")
    guard case .object(let args)? = echoed.rest["arguments"] else {
      Issue.record("Expected arguments object")
      return
    }
    #expect(args["message"] == "hello world")
  }

  @Test func multipleSequentialMessages() async throws {
    let h = makeHarness()
    let conn = h.connection
    defer { Task { await conn.terminate() } }

    _ = try await h.handshake()
    h.sendInitialized()

    for i in 10 ..< 15 {
      h.send(
        #"{"jsonrpc":"2.0","id":\#(i),"method":"tools/call","params":{"name":"echo","arguments":{"index":\#(i)}}}"#
      )
    }

    let envelopes = try await h.collect(count: 5)
    #expect(envelopes.count == 5)

    let ids = envelopes.map { $0.id }
    for i in 10 ..< 15 {
      #expect(ids.contains(JSONValue.number(Decimal(i))))
    }
  }

  @Test func messagesBufferedDuringInit() async throws {
    let h = makeHarness()
    let conn = h.connection
    defer { Task { await conn.terminate() } }

    // Send initialize AND tools/list immediately, before bridge can respond
    h.sendInitialize(id: 1)
    h.sendInitialized()
    h.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)

    let envelopes = try await h.collect(count: 2)
    #expect(envelopes.count == 2)
    #expect(envelopes[0].id == 1)
    #expect(envelopes[1].id == 2)
  }
}
