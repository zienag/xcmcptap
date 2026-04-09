import class Foundation.JSONDecoder
import struct Foundation.Data
import struct Foundation.Decimal
import System
import Testing
import XcodeMCPTapServiceCore
import XcodeMCPTapShared

@Suite(.serialized)
struct MCPProxyTests {
  static let fakeMCPServer: String = {
    var path = FilePath(#filePath)
    path.removeLastComponent()
    path.removeLastComponent()
    path.removeLastComponent()
    path.append("fake-mcp-server.py")
    return path.string
  }()

  func makeBridge() -> BridgeProcess {
    BridgeProcess(
      executable: "/usr/bin/python3",
      arguments: ["-u", Self.fakeMCPServer]
    )
  }

  /// Collects async responses from the router via AsyncStream.
  final class ResponseCollector: Sendable {
    let stream: AsyncStream<String>
    let continuation: AsyncStream<String>.Continuation

    init() {
      (stream, continuation) = AsyncStream.makeStream()
    }

    func nextResponse(timeout: Duration = .seconds(5)) async throws -> String {
      try await withThrowingTaskGroup(of: String?.self) { group in
        group.addTask {
          for await line in self.stream { return line }
          return nil
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          return nil
        }
        guard let result = try await group.next(), let line = result else {
          group.cancelAll()
          throw TimeoutError()
        }
        group.cancelAll()
        return line
      }
    }

    func collect(count: Int, timeout: Duration = .seconds(5)) async throws -> [String] {
      try await withThrowingTaskGroup(of: [String].self) { group in
        group.addTask {
          var lines: [String] = []
          for await line in self.stream {
            lines.append(line)
            if lines.count >= count { break }
          }
          return lines
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          return []
        }
        guard let result = try await group.next(), !result.isEmpty else {
          group.cancelAll()
          throw TimeoutError()
        }
        group.cancelAll()
        return result
      }
    }
  }

  struct TimeoutError: Error {}

  private func decode(_ string: String) throws -> RPCEnvelope {
    try JSONDecoder().decode(RPCEnvelope.self, from: Data(string.utf8))
  }

  // MARK: - Tests

  @Test func initializeHandshake() async throws {
    let bridge = makeBridge()
    let router = MCPRouter(bridge: bridge)
    let collector = ResponseCollector()

    router.sendToClient = { collector.continuation.yield($0) }
    router.start()

    // Send client initialize
    router.handleClientMessage(
      #"{"jsonrpc":"2.0","id":42,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#
    )

    let response = try await collector.nextResponse()
    let envelope = try decode(response)

    // Should have the client's id, not proxy-init
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
    #expect(resultDict["protocolVersion"] == "2024-11-05")

    bridge.terminate()
  }

  @Test func toolsList() async throws {
    let bridge = makeBridge()
    let router = MCPRouter(bridge: bridge)
    let collector = ResponseCollector()

    router.sendToClient = { collector.continuation.yield($0) }
    router.start()

    // Handshake
    router.handleClientMessage(
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#
    )
    _ = try await collector.nextResponse()
    router.handleClientMessage(#"{"jsonrpc":"2.0","method":"initialized"}"#)

    // List tools
    router.handleClientMessage(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)

    let response = try await collector.nextResponse()
    let envelope = try decode(response)

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

    bridge.terminate()
  }

  @Test func toolsCall() async throws {
    let bridge = makeBridge()
    let router = MCPRouter(bridge: bridge)
    let collector = ResponseCollector()

    router.sendToClient = { collector.continuation.yield($0) }
    router.start()

    // Handshake
    router.handleClientMessage(
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#
    )
    _ = try await collector.nextResponse()
    router.handleClientMessage(#"{"jsonrpc":"2.0","method":"initialized"}"#)

    // Call echo tool
    router.handleClientMessage(
      #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello world"}}}"#
    )

    let response = try await collector.nextResponse()
    let envelope = try decode(response)

    #expect(envelope.id == 3)
    guard case .object(let result)? = envelope.rest["result"],
          case .array(let content)? = result["content"],
          case .object(let first)? = content.first,
          case .string(let text)? = first["text"] else {
      Issue.record("Expected result.content[0].text")
      return
    }
    let echoed = try decode(text)
    #expect(echoed.rest["tool"] == "echo")
    guard case .object(let args)? = echoed.rest["arguments"] else {
      Issue.record("Expected arguments object")
      return
    }
    #expect(args["message"] == "hello world")

    bridge.terminate()
  }

  @Test func multipleSequentialMessages() async throws {
    let bridge = makeBridge()
    let router = MCPRouter(bridge: bridge)
    let collector = ResponseCollector()

    router.sendToClient = { collector.continuation.yield($0) }
    router.start()

    // Handshake
    router.handleClientMessage(
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#
    )
    _ = try await collector.nextResponse()
    router.handleClientMessage(#"{"jsonrpc":"2.0","method":"initialized"}"#)

    // Send 5 tool calls
    for i in 10 ..< 15 {
      router.handleClientMessage(
        #"{"jsonrpc":"2.0","id":\#(i),"method":"tools/call","params":{"name":"echo","arguments":{"index":\#(i)}}}"#
      )
    }

    let responses = try await collector.collect(count: 5)
    #expect(responses.count == 5)

    let ids = try responses.map { try decode($0).id }
    for i in 10 ..< 15 {
      #expect(ids.contains(JSONValue.number(Decimal(i))))
    }

    bridge.terminate()
  }

  @Test func messagesBufferedDuringInit() async throws {
    let bridge = makeBridge()
    let router = MCPRouter(bridge: bridge)
    let collector = ResponseCollector()

    router.sendToClient = { collector.continuation.yield($0) }
    router.start()

    // Send initialize AND tools/list immediately, before bridge can respond
    router.handleClientMessage(
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#
    )
    router.handleClientMessage(#"{"jsonrpc":"2.0","method":"initialized"}"#)
    router.handleClientMessage(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)

    // Should get both responses: initialize (from cache) + tools/list (from bridge)
    let responses = try await collector.collect(count: 2)
    #expect(responses.count == 2)

    let first = try decode(responses[0])
    #expect(first.id == 1)

    let second = try decode(responses[1])
    #expect(second.id == 2)

    bridge.terminate()
  }
}
