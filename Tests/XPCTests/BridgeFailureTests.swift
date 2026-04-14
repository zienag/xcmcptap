import struct Foundation.Data
import struct Foundation.Decimal
import class Foundation.JSONDecoder
import class Foundation.NSDecimalNumber
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

/// Pins the router's behavior when the mcpbridge subprocess is broken —
/// either because Xcode isn't running (immediate crash at startup) or
/// because mcpbridge dies mid-session. Every client request must get a
/// response; every notification must be dropped silently. No hangs.
@Suite(.serialized)
struct BridgeFailureTests {
  static let mockBridge = MockBridge.path()

  private func harness(failMode: String) -> RouterHarness {
    RouterHarness(exec: "/usr/bin/python3", "-u", Self.mockBridge, "--fail", failMode)
  }

  private func deadBridgeHarness() -> RouterHarness {
    harness(failMode: "at-startup")
  }

  private func midSessionDeathHarness() -> RouterHarness {
    harness(failMode: "after-init")
  }

  // MARK: - Bridge dies at startup

  /// Bridge crashed before it could complete its init handshake. Client
  /// sends `initialize` — must receive a JSON-RPC error response keyed
  /// to its original id, not hang.
  @Test func initializeRepliesWithErrorWhenBridgeDead() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.sendInitialize(id: 7)

    let envelope = try await h.nextResponse()
    #expect(envelope.id == .number(Decimal(7)))
    #expect(envelope.rest["result"] == nil)
    try requireError(envelope)
  }

  /// Bridge is dead and the spec says requests must get responses; a
  /// tools/call is a request — must get an error back, not silence.
  @Test func toolsCallRepliesWithErrorWhenBridgeDead() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.send(
      #"{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{}}}"#,
    )
    let envelope = try await h.nextResponse()
    #expect(envelope.id == .number(Decimal(99)))
    try requireError(envelope)
  }

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

  /// Messages sent before the router has finished its boot attempt get
  /// buffered in `pending`. When boot fails, that buffer must drain as
  /// error responses — otherwise the client hangs forever.
  @Test func pendingMessagesDrainAsErrorsAfterBootFailure() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.sendInitialize(id: 1)
    h.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    h.send(
      #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"X","arguments":{}}}"#,
    )

    let envelopes = try await h.collect(count: 3)
    let ids = envelopes.compactMap { env -> Int? in
      guard case let .number(n)? = env.id else { return nil }
      return (n as NSDecimalNumber).intValue
    }
    #expect(Set(ids) == [1, 2, 3])
    for env in envelopes {
      try requireError(env)
    }
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
    let envelope = try await h.nextResponse()
    #expect(envelope.id == .number(Decimal(42)))
    try requireError(envelope)
  }

  /// After a mid-session death, subsequent client requests must also
  /// receive errors — the router's state is permanently `.failed` for
  /// the lifetime of the process. No silent hangs.
  @Test func subsequentRequestsAfterMidSessionDeathGetErrors() async throws {
    let h = midSessionDeathHarness()
    defer { Task { await h.terminate() } }

    _ = try await h.handshake(id: 1)
    h.sendInitialized()

    h.send(
      #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"X","arguments":{}}}"#,
    )
    _ = try await h.nextResponse()

    h.send(#"{"jsonrpc":"2.0","id":11,"method":"tools/list"}"#)
    let envelope = try await h.nextResponse()
    #expect(envelope.id == .number(Decimal(11)))
    try requireError(envelope)
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
