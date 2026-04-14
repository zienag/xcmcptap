import class Foundation.JSONDecoder
import struct Foundation.Data
import struct Foundation.Decimal
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

@Suite(.serialized)
struct MCPProxyTests {
  static let mockBridge = MockBridge.path()

  private func makeHarness() -> RouterHarness {
    .mock(bridge: Self.mockBridge)
  }

  // MARK: - Tests

  @Test func initializeHandshake() async throws {
    let h = makeHarness()
    defer { Task { await h.terminate() } }

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
    #expect(serverInfo["name"] == "xcode-tools")
    #expect(resultDict["protocolVersion"] == .string("2025-06-18"))
  }

  @Test func toolsList() async throws {
    let h = makeHarness()
    defer { Task { await h.terminate() } }

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
    #expect(toolNames.contains("BuildProject"))
    #expect(toolNames.contains("XcodeGrep"))
    #expect(toolNames.contains("XcodeRead"))
    #expect(toolNames.contains("XcodeListWindows"))
  }

  @Test func toolsCall() async throws {
    let h = makeHarness()
    defer { Task { await h.terminate() } }

    _ = try await h.handshake()
    h.sendInitialized()
    h.send(
      #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{"tabIdentifier":"windowtab1","pattern":"hello world"}}}"#
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
    #expect(echoed.rest["tool"] == "XcodeGrep")
    guard case .object(let args)? = echoed.rest["arguments"] else {
      Issue.record("Expected arguments object")
      return
    }
    #expect(args["pattern"] == "hello world")
    #expect(args["tabIdentifier"] == "windowtab1")
  }

  @Test func multipleSequentialMessages() async throws {
    let h = makeHarness()
    defer { Task { await h.terminate() } }

    _ = try await h.handshake()
    h.sendInitialized()

    for i in 10 ..< 15 {
      h.send(
        #"{"jsonrpc":"2.0","id":\#(i),"method":"tools/call","params":{"name":"XcodeGrep","arguments":{"tabIdentifier":"windowtab1","pattern":"q\#(i)"}}}"#
      )
    }

    let envelopes = try await h.collect(count: 5)
    #expect(envelopes.count == 5)

    let ids = envelopes.map { $0.id }
    for i in 10 ..< 15 {
      #expect(ids.contains(JSONValue.number(Decimal(i))))
    }
  }

  /// Replays the exact wire traffic captured from Claude Code hitting
  /// `mcp__xcode__XcodeListWindows` against mock-mcpbridge. Pins:
  ///  - Claude Code's field ordering (method first, jsonrpc last, id last)
  ///  - `_meta.claudecode/toolUseId` and `progressToken` in params
  ///  - mcpbridge's response shape: content[0].text carries a JSON-encoded
  ///    projection of structuredContent, and id is preserved verbatim.
  @Test func xcodeListWindowsClaudeCodeStyle() async throws {
    let h = makeHarness()
    defer { Task { await h.terminate() } }

    // 1. initialize — Claude Code field ordering, with roots/elicitation.
    h.send(
      #"{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{},"elicitation":{}},"clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.101"}},"jsonrpc":"2.0","id":0}"#
    )
    let initEnvelope = try await h.nextResponse()
    #expect(initEnvelope.id == 0)
    let initResult = try initEnvelope.decodeResult(as: InitializeResult.self)
    #expect(initResult.serverInfo.name == "xcode-tools")
    #expect(initResult.protocolVersion == "2025-06-18")

    // 2. notifications/initialized (Claude Code ordering: method first).
    h.send(#"{"method":"notifications/initialized","jsonrpc":"2.0"}"#)

    // 3. tools/list — verify XcodeListWindows is present.
    h.send(#"{"method":"tools/list","jsonrpc":"2.0","id":1}"#)
    let toolsListEnvelope = try await h.nextResponse()
    #expect(toolsListEnvelope.id == 1)
    let toolsList = try toolsListEnvelope.decodeResult(as: ListToolsResult.self)
    #expect(toolsList.tools.contains { $0.name == "XcodeListWindows" })

    // 4. tools/call XcodeListWindows — Claude Code shape with _meta.
    h.send(
      #"{"method":"tools/call","params":{"name":"XcodeListWindows","arguments":{},"_meta":{"claudecode/toolUseId":"toolu_0114g49Lk5nHcE9J48JsLL4a","progressToken":2}},"jsonrpc":"2.0","id":2}"#
    )
    let callEnvelope = try await h.nextResponse()
    #expect(callEnvelope.id == 2)

    guard case .object(let callResult)? = callEnvelope.rest["result"] else {
      Issue.record("expected result object, got \(String(describing: callEnvelope.rest["result"]))")
      return
    }

    // structuredContent.message
    guard case .object(let structured)? = callResult["structuredContent"],
          case .string(let structuredMessage)? = structured["message"] else {
      Issue.record("expected structuredContent.message string")
      return
    }
    #expect(structuredMessage.contains("tabIdentifier: windowtab2"))
    #expect(structuredMessage.contains("tabIdentifier: windowtab1"))
    #expect(structuredMessage.contains("Multivibe.xcworkspace"))
    #expect(structuredMessage.contains("XcodeMCPTap.xcodeproj"))

    // content[0].text is a JSON-encoded {"message": ...} — same data as
    // structuredContent but string-wrapped, matching real mcpbridge.
    guard case .array(let content)? = callResult["content"],
          case .object(let first)? = content.first,
          case .string(let textKind)? = first["type"],
          case .string(let jsonText)? = first["text"] else {
      Issue.record("expected result.content[0] = {type: text, text: string}")
      return
    }
    #expect(textKind == "text")
    let decoded = try JSONDecoder().decode(
      [String: String].self, from: Data(jsonText.utf8)
    )
    #expect(decoded["message"] == structuredMessage)
  }

  @Test func messagesBufferedDuringInit() async throws {
    let h = makeHarness()
    defer { Task { await h.terminate() } }

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
