import class Foundation.JSONSerialization
import struct Foundation.Data
import Synchronization
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
    let json = try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: Any]

    // Should have the client's id, not proxy-init
    #expect(json["id"] as? Int == 42)
    #expect(json["jsonrpc"] as? String == "2.0")

    let result = json["result"] as! [String: Any]
    let serverInfo = result["serverInfo"] as! [String: Any]
    #expect(serverInfo["name"] as? String == "fake-mcp-server")
    #expect(result["protocolVersion"] as? String == "2024-11-05")

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
    let json = try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: Any]

    #expect(json["id"] as? Int == 2)
    let result = json["result"] as! [String: Any]
    let tools = result["tools"] as! [[String: Any]]
    let toolNames = tools.map { $0["name"] as! String }
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
    let json = try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: Any]

    #expect(json["id"] as? Int == 3)
    let result = json["result"] as! [String: Any]
    let content = result["content"] as! [[String: Any]]
    let text = content[0]["text"] as! String
    let echoed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    #expect(echoed["tool"] as? String == "echo")
    let args = echoed["arguments"] as! [String: Any]
    #expect(args["message"] as? String == "hello world")

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

    for response in responses {
      let json = try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: Any]
      let id = json["id"] as! Int
      #expect(id >= 10 && id < 15)
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

    let first = try JSONSerialization.jsonObject(with: Data(responses[0].utf8)) as! [String: Any]
    #expect(first["id"] as? Int == 1)

    let second = try JSONSerialization.jsonObject(with: Data(responses[1].utf8)) as! [String: Any]
    #expect(second["id"] as? Int == 2)

    bridge.terminate()
  }
}
