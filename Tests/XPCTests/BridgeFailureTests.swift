import struct Foundation.Data
import struct Foundation.Decimal
import class Foundation.JSONDecoder
import class Foundation.NSDecimalNumber
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

/// Pins the router's behavior when the mcpbridge subprocess is broken —
/// either because Xcode isn't running (immediate crash at startup) or
/// because mcpbridge dies mid-session.
///
/// The user-visible contract is split between two suites:
///  - `FallbackToolTests` — the synthetic `initialize`, fallback
///    `tools/list`, and `xcmcptap_status` / `xcmcptap_reload` flow.
///  - `BridgeFailureTests` (this file) — the protocol-level invariants
///    that hold regardless of fallback content: in-flight requests get
///    answered, unknown methods get JSON-RPC errors, notifications drop
///    silently, no client is ever left hanging.
@Suite(.serialized)
struct BridgeFailureTests {
  static let mockBridge = MockBridge.path()

  private func deadBridgeHarness() -> RouterHarness {
    RouterHarness(exec: "/usr/bin/python3", "-u", Self.mockBridge, "--fail", "at-startup")
  }

  private func midSessionDeathHarness() -> RouterHarness {
    RouterHarness(exec: "/usr/bin/python3", "-u", Self.mockBridge, "--fail", "after-init")
  }

  // MARK: - Bridge dies at startup

  /// Notifications (no id) have no response per JSON-RPC spec. The
  /// router must drop them silently even when the bridge is dead —
  /// never emit a bare error envelope with id=null.
  @Test func notificationsDroppedSilentlyWhenBridgeDead() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    h.send(
      #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1,"reason":"x"}}"#,
    )

    await #expect(throws: TimeoutError.self) {
      _ = try await h.collector.nextResponse(timeout: .milliseconds(300))
    }
  }

  /// A `tools/call` aimed at a tool the proxy doesn't expose in fallback
  /// mode (i.e., not `xcmcptap_status` / `xcmcptap_reload`) must surface
  /// an MCP-shaped error result with `isError: true`. This shouldn't
  /// arise in practice — the agent only sees fallback tools — but if a
  /// stale tool name leaks through from a previous session, we owe the
  /// client a clear answer rather than silence.
  @Test func unknownToolCallReturnsErrorResultWhenBridgeDead() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.sendInitialize(id: 1)
    _ = try await h.nextResponse()
    h.sendInitialized()

    h.send(
      #"{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{}}}"#,
    )
    let envelope = try await h.nextResponse()
    #expect(envelope.id == .number(Decimal(99)))
    #expect(envelope.rest["error"] == nil)
    guard case let .object(result)? = envelope.rest["result"],
          case let .bool(isError)? = result["isError"]
    else {
      Issue.record("expected result.isError on unknown tool call")
      return
    }
    #expect(isError == true)
  }

  /// Methods other than `initialize` / `tools/list` / `tools/call` /
  /// known notifications still need a response when sent as a request.
  /// JSON-RPC -32601 (method not found) is correct here — the proxy
  /// genuinely doesn't implement them in fallback mode.
  @Test func unknownMethodReturnsJsonRpcErrorWhenBridgeDead() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.sendInitialize(id: 1)
    _ = try await h.nextResponse()
    h.sendInitialized()

    h.send(#"{"jsonrpc":"2.0","id":50,"method":"resources/list"}"#)
    let envelope = try await h.nextResponse()
    #expect(envelope.id == .number(Decimal(50)))
    try requireError(envelope)
  }

  /// Messages sent before the router has finished its first boot attempt
  /// queue in `pending`. When that boot fails, the queue must drain such
  /// that every request gets a terminating reply — for `initialize` and
  /// `tools/list` that means fallback responses; for unknown methods,
  /// JSON-RPC errors. No request may be left hanging.
  @Test func pendingMessagesDrainAsFallbackAfterBootFailure() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.sendInitialize(id: 1)
    h.sendInitialized()
    h.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    h.send(
      #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{}}}"#,
    )

    let envelopes = try await h.collect(count: 3)
    let byId: [Decimal: RPCEnvelope] = Dictionary(
      uniqueKeysWithValues: envelopes.compactMap { env in
        guard case let .number(n)? = env.id else { return nil }
        return (n, env)
      },
    )

    let initEnv = try #require(byId[Decimal(1)])
    #expect(initEnv.rest["error"] == nil)
    _ = try initEnv.decodeResult(as: InitializeResult.self)

    let listEnv = try #require(byId[Decimal(2)])
    #expect(listEnv.rest["error"] == nil)
    let listResult = try listEnv.decodeResult(as: ListToolsResult.self)
    #expect(listResult.tools.contains { $0.name == "xcmcptap_status" })

    let callEnv = try #require(byId[Decimal(3)])
    #expect(callEnv.rest["error"] == nil)
    guard case let .object(callResult)? = callEnv.rest["result"],
          case let .bool(isError)? = callResult["isError"]
    else {
      Issue.record("expected isError on unknown tool/call")
      return
    }
    #expect(isError == true)
  }

  // MARK: - Bridge dies mid-session

  /// Init succeeds, then the bridge crashes on the first tools/call.
  /// The client's request is in flight (registered in `idMap`). The
  /// router must surface an error for that id when the subprocess dies.
  @Test func inFlightRequestRepliesWithErrorWhenBridgeDiesMidSession() async throws {
    let h = midSessionDeathHarness()
    defer { Task { await h.terminate() } }

    _ = try await h.handshake(id: 1)
    h.sendInitialized()

    h.send(
      #"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{}}}"#,
    )

    // Two messages arrive (in either order): the in-flight error for
    // id=42 and a tools/list_changed broadcast. We're only asserting on
    // the error here; the broadcast is pinned by FallbackToolTests.
    var errorEnvelope: RPCEnvelope?
    for _ in 0 ..< 2 {
      let env = try await h.nextResponse(timeout: .seconds(10))
      if env.id == .number(Decimal(42)) {
        errorEnvelope = env
      }
    }
    let envelope = try #require(errorEnvelope)
    try requireError(envelope)
  }

  /// After a mid-session death, follow-up `tools/list` must return the
  /// fallback toolset (proving the router transitioned to fallback
  /// mode), and unknown tool calls must surface an isError result.
  @Test func subsequentRequestsAfterMidSessionDeathRouteToFallback() async throws {
    let h = midSessionDeathHarness()
    defer { Task { await h.terminate() } }

    _ = try await h.handshake(id: 1)
    h.sendInitialized()

    // Trigger the mid-session crash; the router emits two messages
    // (id=10 error reply + tools/list_changed broadcast) — drain both.
    h.send(
      #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"X","arguments":{}}}"#,
    )
    for _ in 0 ..< 2 {
      _ = try await h.nextResponse(timeout: .seconds(5))
    }

    // Now ask for tools/list — must come back as fallback.
    h.send(#"{"jsonrpc":"2.0","id":11,"method":"tools/list"}"#)
    let envelope = try await h.nextResponse()
    #expect(envelope.id == .number(Decimal(11)))
    let result = try envelope.decodeResult(as: ListToolsResult.self)
    #expect(result.tools.map(\.name) == ["xcmcptap_status", "xcmcptap_reload"])
  }

  // MARK: - Helpers

  private func requireError(_ envelope: RPCEnvelope) throws {
    guard case let .object(err)? = envelope.rest["error"] else {
      Issue.record("expected error envelope, got \(envelope.rest)")
      return
    }
    #expect(err["code"] != nil)
    guard case let .string(message)? = err["message"] else {
      Issue.record("expected string error message, got \(String(describing: err["message"]))")
      return
    }
    #expect(!message.isEmpty)
  }

}
