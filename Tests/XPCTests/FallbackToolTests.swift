import struct Foundation.Data
import struct Foundation.Decimal
import class Foundation.JSONDecoder
import class Foundation.NSDecimalNumber
import struct Foundation.UUID
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

/// When mcpbridge is unavailable (Xcode not running, mid-session crash, …)
/// the proxy must NOT make the MCP session unusable. Instead it serves a
/// synthetic `initialize` response and exposes a tiny fallback toolset —
/// `xcmcptap_status` (read-only inspection) and `xcmcptap_reload` (explicit
/// recovery). When the bridge recovers (via reload or a future external
/// trigger) the proxy emits `notifications/tools/list_changed` so the host
/// re-fetches the real tool list.
@Suite(.serialized)
struct FallbackToolTests {
  static let mockBridge = MockBridge.path()

  private func deadBridgeHarness() -> RouterHarness {
    RouterHarness(exec: "/usr/bin/python3", "-u", Self.mockBridge, "--fail", "at-startup")
  }

  private func midSessionDeathHarness() -> RouterHarness {
    RouterHarness(exec: "/usr/bin/python3", "-u", Self.mockBridge, "--fail", "after-init")
  }

  // MARK: - Synthetic initialize

  /// A client connecting while the bridge is dead must receive a real
  /// `initialize` *result* (not a JSON-RPC error), so the MCP session
  /// itself succeeds and the client can proceed to fetch tools.
  @Test func initializeReturnsSyntheticResultWhenBridgeDead() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.sendInitialize(id: 1)

    let envelope = try await h.nextResponse()
    #expect(envelope.id == .number(Decimal(1)))
    #expect(envelope.rest["error"] == nil)
    let result = try envelope.decodeResult(as: InitializeResult.self)
    #expect(result.serverInfo.name == "xcmcptap")
  }

  /// The synthetic init response must advertise `tools.listChanged: true`
  /// so the host watches for our recovery notification and re-fetches
  /// `tools/list` after the bridge comes back.
  @Test func syntheticInitAdvertisesToolsListChanged() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.sendInitialize(id: 1)

    let envelope = try await h.nextResponse()
    guard case let .object(result)? = envelope.rest["result"],
          case let .object(caps)? = result["capabilities"],
          case let .object(toolCaps)? = caps["tools"],
          case let .bool(listChanged)? = toolCaps["listChanged"]
    else {
      Issue.record("expected capabilities.tools.listChanged in synthetic init")
      return
    }
    #expect(listChanged == true)
  }

  // MARK: - Synthetic tools/list

  /// `tools/list` while the bridge is dead must return ONLY the proxy's
  /// own fallback tools — never an error, never an empty list, never the
  /// real Xcode tools (which would be a lie).
  @Test func toolsListReturnsFallbackToolsWhenBridgeDead() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.sendInitialize(id: 1)
    _ = try await h.nextResponse()
    h.sendInitialized()

    h.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    let envelope = try await h.nextResponse()
    #expect(envelope.id == .number(Decimal(2)))
    #expect(envelope.rest["error"] == nil)
    let names = try toolNames(from: envelope)
    #expect(Set(names) == ["xcmcptap_status", "xcmcptap_reload"])
  }

  // MARK: - xcmcptap_status

  /// `xcmcptap_status` is the read-only inspection tool. It must include
  /// the actual failure reason captured from mcpbridge's stderr (or a
  /// transport error), not a generic "unavailable" placeholder.
  @Test func statusToolReturnsBridgeReason() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.sendInitialize(id: 1)
    _ = try await h.nextResponse()
    h.sendInitialized()

    h.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"xcmcptap_status","arguments":{}}}"#)
    let envelope = try await h.nextResponse()
    #expect(envelope.id == .number(Decimal(3)))
    let text = try toolCallText(from: envelope)
    // The mock at-startup mode emits the real mcpbridge fatal-error string
    // including "MCP_XCODE_PID environment variable not set" — that must
    // surface verbatim so users / agents know exactly what went wrong.
    #expect(text.contains("MCP_XCODE_PID"))
  }

  /// `xcmcptap_status` must NOT trigger a respawn — it's read-only.
  /// After calling it, state must still be `.failed`, so a follow-up
  /// `tools/list` still returns fallback tools, not real ones.
  @Test func statusToolDoesNotTriggerRespawn() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.sendInitialize(id: 1)
    _ = try await h.nextResponse()
    h.sendInitialized()

    h.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"xcmcptap_status","arguments":{}}}"#)
    _ = try await h.nextResponse()

    h.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
    let envelope = try await h.nextResponse()
    let names = try toolNames(from: envelope)
    #expect(Set(names) == ["xcmcptap_status", "xcmcptap_reload"])
  }

  // MARK: - xcmcptap_reload

  /// Reload against a still-broken bridge must return a proper tool
  /// result with `isError: true` and the fresh failure reason — NOT a
  /// JSON-RPC error envelope (the agent should display the text to the
  /// user, not surface a protocol error).
  @Test func reloadToolReturnsErrorResultWhenStillBroken() async throws {
    let h = deadBridgeHarness()
    defer { Task { await h.terminate() } }

    h.sendInitialize(id: 1)
    _ = try await h.nextResponse()
    h.sendInitialized()

    h.send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"xcmcptap_reload","arguments":{}}}"#)
    let envelope = try await h.nextResponse(timeout: .seconds(10))
    #expect(envelope.id == .number(Decimal(5)))
    #expect(envelope.rest["error"] == nil)
    guard case let .object(result)? = envelope.rest["result"],
          case let .bool(isError)? = result["isError"]
    else {
      Issue.record("expected result.isError on failed reload")
      return
    }
    #expect(isError == true)
    let text = try toolCallText(from: envelope)
    #expect(text.contains("MCP_XCODE_PID"))
  }

  /// Reload against a bridge that comes back healthy on the second
  /// attempt must:
  /// 1. Reply with a success-shaped tool result (no isError flag).
  /// 2. Emit `notifications/tools/list_changed` so the host re-fetches.
  /// 3. Make subsequent `tools/list` return the real Xcode tools, not
  ///    fallback tools.
  @Test func reloadToolRecoversBridgeAndBroadcastsListChanged() async throws {
    let attempts = AttemptCounter()
    let factory: @Sendable () -> MCPConnection = {
      let n = attempts.next()
      let failMode = n == 1 ? "at-startup" : "normal"
      return MCPConnection(
        serviceName: testServiceName,
        exec: "/usr/bin/python3",
        args: ["-u", Self.mockBridge, "--fail", failMode],
      )
    }
    let router = MCPRouter(serviceName: testServiceName, clientName: "XcodeMCPTap", makeConnection: factory)
    let collector = ResponseCollector()
    let clientID = router.registerClient { [collector] line in
      collector.continuation.yield(line)
    }
    router.start()
    defer { Task { await router.shutdown() } }

    // Initial handshake: bridge is dead, client gets fallback init.
    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(MCPProtocol.version)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
    )
    _ = try await collector.nextResponse()
    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
    )

    // Reload — second-attempt factory returns a healthy bridge.
    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"xcmcptap_reload","arguments":{}}}"#,
    )

    // Two messages must arrive (in either order): the reload response
    // and the tools/list_changed broadcast. Assert both are present.
    var sawReloadSuccess = false
    var sawListChanged = false
    for _ in 0 ..< 2 {
      let raw = try await collector.nextResponse(timeout: .seconds(10))
      let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: Data(raw.utf8))
      if envelope.id == .number(Decimal(7)) {
        guard case let .object(result)? = envelope.rest["result"] else {
          Issue.record("reload response missing result")
          continue
        }
        if case .bool(true)? = result["isError"] {
          Issue.record("reload reported failure on healthy second attempt")
        }
        sawReloadSuccess = true
      } else if envelope.method == "notifications/tools/list_changed" {
        sawListChanged = true
      }
    }
    #expect(sawReloadSuccess)
    #expect(sawListChanged)

    // Subsequent tools/list must return the REAL Xcode tools, proving
    // the router has switched out of fallback mode.
    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","id":8,"method":"tools/list"}"#,
    )
    let raw = try await collector.nextResponse(timeout: .seconds(5))
    let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: Data(raw.utf8))
    let names = try toolNames(from: envelope)
    #expect(names.contains("BuildProject"))
    #expect(names.contains("XcodeListWindows"))
    #expect(!names.contains("xcmcptap_status"))
  }

  // MARK: - First-ever .ready does not broadcast

  /// `notifications/tools/list_changed` is reserved for the
  /// failure-then-recovery transitions where clients have a stale
  /// real-tool cache to throw away. A normal startup (no prior
  /// failure) must NOT emit it — broadcasting on every boot would
  /// trigger spurious refetches the moment a client connects to a
  /// fresh service. The router guards this with `hasObservedFailure`.
  @Test func firstEverReadyDoesNotBroadcastToolsListChanged() async throws {
    let recorder = StatusRecorder()
    let collector = ResponseCollector()
    let router = MCPRouter(serviceName: testServiceName, clientName: "XcodeMCPTap", makeConnection: {
      MCPConnection(serviceName: testServiceName, exec: "/usr/bin/python3", args: ["-u", Self.mockBridge])
    })
    router.onBridgeStateChanged = { recorder.append($0) }
    _ = router.registerClient { [collector] line in
      collector.continuation.yield(line)
    }
    router.start()
    defer { Task { await router.shutdown() } }

    try await recorder.waitFor(.ready, timeout: .seconds(5))

    // The client never sent anything, so the only thing that could
    // arrive is a spurious broadcast — assert silence.
    await #expect(throws: TimeoutError.self) {
      _ = try await collector.nextResponse(timeout: .milliseconds(300))
    }
  }

  // MARK: - Mid-session crash → list_changed broadcast

  /// When the bridge dies mid-session, every connected client must be
  /// told via `notifications/tools/list_changed` so they re-fetch and
  /// see the fallback tool list. Otherwise they keep showing real tools
  /// from a stale cache that no longer works.
  @Test func midSessionFailureBroadcastsToolsListChanged() async throws {
    let h = midSessionDeathHarness()
    defer { Task { await h.terminate() } }

    _ = try await h.handshake(id: 1)
    h.sendInitialized()

    // First post-init request triggers the simulated mid-session crash.
    h.send(
      #"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{}}}"#,
    )

    // Two responses: the in-flight error reply for id=42 and the
    // tools/list_changed broadcast announcing the degradation.
    var sawErrorForCall = false
    var sawListChanged = false
    for _ in 0 ..< 2 {
      let envelope = try await h.nextResponse(timeout: .seconds(10))
      if envelope.id == .number(Decimal(42)) {
        sawErrorForCall = envelope.rest["error"] != nil
      } else if envelope.method == "notifications/tools/list_changed" {
        sawListChanged = true
      }
    }
    #expect(sawErrorForCall)
    #expect(sawListChanged)
  }

  /// The `tools/list_changed` broadcast must reach EVERY connected
  /// client, not just the one whose request triggered the crash. A
  /// passive observer (no in-flight request, no recent traffic) needs
  /// the notification just as much — its cached real-tool list is now
  /// equally stale. Regression guard against the original
  /// "global sendToClient" multi-client routing bug, applied to the
  /// broadcast path.
  @Test func midSessionCrashBroadcastsToAllConnectedClients() async throws {
    let connection = MCPConnection(
      serviceName: testServiceName,
      exec: "/usr/bin/python3",
      args: ["-u", Self.mockBridge, "--fail", "after-init"],
    )
    let router = MCPRouter(serviceName: testServiceName, clientName: testIdentity.appDisplayName, connection: connection)
    let collectorA = ResponseCollector()
    let collectorB = ResponseCollector()
    let idA = router.registerClient { [collectorA] line in
      collectorA.continuation.yield(line)
    }
    let idB = router.registerClient { [collectorB] line in
      collectorB.continuation.yield(line)
    }
    router.start()
    defer { Task { await connection.terminate() } }

    // Both clients complete their handshake and sit idle.
    for id in [idA, idB] {
      router.handleClientMessage(
        from: id,
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(MCPProtocol.version)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
      )
    }
    _ = try await collectorA.nextResponse()
    _ = try await collectorB.nextResponse()
    for id in [idA, idB] {
      router.handleClientMessage(
        from: id,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
      )
    }

    // Only A makes the call that trips the crash. B is a bystander.
    router.handleClientMessage(
      from: idA,
      #"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{}}}"#,
    )

    // A receives two messages: the in-flight error reply for id=42
    // and the broadcast. Order is unspecified — assert both arrive.
    var sawErrorForA = false
    var sawListChangedOnA = false
    for _ in 0 ..< 2 {
      let raw = try await collectorA.nextResponse(timeout: .seconds(10))
      let env = try JSONDecoder().decode(RPCEnvelope.self, from: Data(raw.utf8))
      if env.id == .number(Decimal(42)), env.rest["error"] != nil {
        sawErrorForA = true
      } else if env.method == "notifications/tools/list_changed" {
        sawListChangedOnA = true
      }
    }
    #expect(sawErrorForA)
    #expect(sawListChangedOnA)

    // B has no in-flight request, so the ONLY thing it can legitimately
    // receive is the broadcast. If multi-client routing regressed and
    // the broadcast went only to A, B would time out here.
    let rawB = try await collectorB.nextResponse(timeout: .seconds(10))
    let envB = try JSONDecoder().decode(RPCEnvelope.self, from: Data(rawB.utf8))
    #expect(envB.method == "notifications/tools/list_changed")
  }

  // MARK: - Helpers

  private func toolNames(from envelope: RPCEnvelope) throws -> [String] {
    guard case let .object(result)? = envelope.rest["result"],
          case let .array(tools)? = result["tools"] else { return [] }
    return tools.compactMap { tool -> String? in
      guard case let .object(t) = tool, case let .string(name)? = t["name"] else { return nil }
      return name
    }
  }

  private func toolCallText(from envelope: RPCEnvelope) throws -> String {
    guard case let .object(result)? = envelope.rest["result"],
          case let .array(content)? = result["content"],
          case let .object(first)? = content.first,
          case let .string(text)? = first["text"]
    else {
      Issue.record("expected result.content[0].text on tool call")
      return ""
    }
    return text
  }
}

extension RouterHarness {
  func nextResponse(timeout: Duration) async throws -> RPCEnvelope {
    let line = try await collector.nextResponse(timeout: timeout)
    return try JSONDecoder().decode(RPCEnvelope.self, from: Data(line.utf8))
  }
}
