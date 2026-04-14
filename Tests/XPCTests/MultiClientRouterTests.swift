import struct Foundation.Data
import struct Foundation.Decimal
import class Foundation.JSONDecoder
import struct Foundation.UUID
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

/// Regression suite for the multi-client routing bug: a single `MCPRouter`
/// shared by two XPC connections was using a global `sendToClient`, so
/// responses to client A's tool calls were delivered to client B and
/// vice-versa whenever the connection order interleaved. See
/// CLAUDE.md "Current Blocker" history.
@Suite(.serialized)
struct MultiClientRouterTests {
  static let mockBridge = MockBridge.path()

  private func startSharedRouter() -> (
    router: MCPRouter,
    connection: MCPConnection,
    a: (id: UUID, responses: ResponseCollector),
    b: (id: UUID, responses: ResponseCollector),
  ) {
    let connection = MCPConnection(exec: "/usr/bin/python3", args: ["-u", Self.mockBridge])
    let router = MCPRouter(connection: connection)
    let collectorA = ResponseCollector()
    let collectorB = ResponseCollector()
    let idA = router.registerClient { [collectorA] line in
      collectorA.continuation.yield(line)
    }
    let idB = router.registerClient { [collectorB] line in
      collectorB.continuation.yield(line)
    }
    router.start()
    return (router, connection, (idA, collectorA), (idB, collectorB))
  }

  private func initializeClient(_ router: MCPRouter, id: UUID) {
    router.handleClientMessage(
      from: id,
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(MCPProtocol.version)","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#,
    )
    router.handleClientMessage(
      from: id,
      #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
    )
  }

  /// Two clients call a tool using the SAME JSON-RPC id. Each must receive
  /// back its own response, not the other's. Without per-client id
  /// translation this fails because bridge responses are routed by id only.
  @Test func sameIdNoCollision() async throws {
    let (router, connection, a, b) = startSharedRouter()
    defer { Task { await connection.terminate() } }

    initializeClient(router, id: a.id)
    initializeClient(router, id: b.id)
    _ = try await a.responses.nextResponse()
    _ = try await b.responses.nextResponse()

    // Both use id=5. Arguments differ so we can verify each side got
    // the correct echo back.
    router.handleClientMessage(
      from: a.id,
      #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{"pattern":"from-A","tabIdentifier":"t1"}}}"#,
    )
    router.handleClientMessage(
      from: b.id,
      #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{"pattern":"from-B","tabIdentifier":"t2"}}}"#,
    )

    let rawA = try await a.responses.nextResponse()
    let rawB = try await b.responses.nextResponse()

    let envA = try JSONDecoder().decode(RPCEnvelope.self, from: Data(rawA.utf8))
    let envB = try JSONDecoder().decode(RPCEnvelope.self, from: Data(rawB.utf8))

    #expect(envA.id == 5)
    #expect(envB.id == 5)

    try #require(try extractEchoedPattern(from: envA) == "from-A")
    try #require(try extractEchoedPattern(from: envB) == "from-B")
  }

  /// Only client A sends a request. Client B must not receive a stray
  /// response for it — previously, the global `sendToClient` was set to
  /// whoever connected last, so B would get A's response.
  @Test func responsesNeverCrossClients() async throws {
    let (router, connection, a, b) = startSharedRouter()
    defer { Task { await connection.terminate() } }

    initializeClient(router, id: a.id)
    initializeClient(router, id: b.id)
    _ = try await a.responses.nextResponse()
    _ = try await b.responses.nextResponse()

    router.handleClientMessage(
      from: a.id,
      #"{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{"pattern":"only-A","tabIdentifier":"t1"}}}"#,
    )

    let rawA = try await a.responses.nextResponse()
    let envA = try JSONDecoder().decode(RPCEnvelope.self, from: Data(rawA.utf8))
    #expect(envA.id == 99)

    // B should receive nothing within the timeout window.
    await #expect(throws: TimeoutError.self) {
      _ = try await b.responses.nextResponse(timeout: .milliseconds(250))
    }
  }

  /// After `unregisterClient`, the disconnected client's collector must
  /// never receive another message — even for responses the bridge emits
  /// for an already-in-flight request. A subsequent client reusing the
  /// same original id must still be routed correctly.
  @Test func unregisterScrubsPendingMappings() async throws {
    let (router, connection, a, b) = startSharedRouter()
    defer { Task { await connection.terminate() } }

    initializeClient(router, id: a.id)
    _ = try await a.responses.nextResponse()

    // A fires a request then disconnects before the response arrives.
    router.handleClientMessage(
      from: a.id,
      #"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{"pattern":"A","tabIdentifier":"t1"}}}"#,
    )
    router.unregisterClient(id: a.id)

    // B joins, uses the exact same original id=42, should get its own reply.
    initializeClient(router, id: b.id)
    _ = try await b.responses.nextResponse()
    router.handleClientMessage(
      from: b.id,
      #"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{"pattern":"from-B","tabIdentifier":"t2"}}}"#,
    )
    let rawB = try await b.responses.nextResponse()
    let envB = try JSONDecoder().decode(RPCEnvelope.self, from: Data(rawB.utf8))
    #expect(envB.id == 42)
    #expect(try extractEchoedPattern(from: envB) == "from-B")

    // A's collector must see nothing in the meantime.
    await #expect(throws: TimeoutError.self) {
      _ = try await a.responses.nextResponse(timeout: .milliseconds(250))
    }
  }

  /// A client that registers AFTER the bridge has already finished its
  /// init handshake must still receive the cached `initialize` response
  /// when it issues its own handshake.
  @Test func lateClientReceivesCachedInit() async throws {
    let connection = MCPConnection(exec: "/usr/bin/python3", args: ["-u", Self.mockBridge])
    let router = MCPRouter(connection: connection)
    defer { Task { await connection.terminate() } }

    let firstResponses = ResponseCollector()
    let first = router.registerClient { [firstResponses] line in
      firstResponses.continuation.yield(line)
    }
    router.start()

    // Drive the bridge through init via the first client.
    initializeClient(router, id: first)
    _ = try await firstResponses.nextResponse()

    // Now join a second client and issue initialize — should get cached reply.
    let lateResponses = ResponseCollector()
    let late = router.registerClient { [lateResponses] line in
      lateResponses.continuation.yield(line)
    }
    router.handleClientMessage(
      from: late,
      #"{"jsonrpc":"2.0","id":99,"method":"initialize","params":{"protocolVersion":"\#(MCPProtocol.version)","capabilities":{},"clientInfo":{"name":"late","version":"1.0"}}}"#,
    )

    let raw = try await lateResponses.nextResponse()
    let env = try JSONDecoder().decode(RPCEnvelope.self, from: Data(raw.utf8))
    #expect(env.id == 99)
    let result = try env.decodeResult(as: InitializeResult.self)
    #expect(result.serverInfo.name == "xcode-tools")
  }

  /// Requests from two clients that arrive BEFORE the bridge's init
  /// handshake completes are buffered, then flushed once the bridge is
  /// ready — each client's replies must still land in its own collector.
  @Test func bufferedMessagesRouteToCorrectClient() async throws {
    let (router, connection, a, b) = startSharedRouter()
    defer { Task { await connection.terminate() } }

    // Fire everything immediately; bridge Python subprocess needs time to
    // spin up, so these go into `pending` and get replayed post-boot.
    initializeClient(router, id: a.id)
    initializeClient(router, id: b.id)
    router.handleClientMessage(
      from: a.id,
      #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{"pattern":"buffered-A","tabIdentifier":"t1"}}}"#,
    )
    router.handleClientMessage(
      from: b.id,
      #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{"pattern":"buffered-B","tabIdentifier":"t2"}}}"#,
    )

    // Each side sees its init reply + its tools/call reply, in that order.
    let aInit = try await a.responses.nextResponse()
    let aInitEnv = try JSONDecoder().decode(RPCEnvelope.self, from: Data(aInit.utf8))
    #expect(aInitEnv.id == 1)

    let aCall = try await a.responses.nextResponse()
    let aCallEnv = try JSONDecoder().decode(RPCEnvelope.self, from: Data(aCall.utf8))
    #expect(aCallEnv.id == 7)
    #expect(try extractEchoedPattern(from: aCallEnv) == "buffered-A")

    let bInit = try await b.responses.nextResponse()
    let bInitEnv = try JSONDecoder().decode(RPCEnvelope.self, from: Data(bInit.utf8))
    #expect(bInitEnv.id == 1)

    let bCall = try await b.responses.nextResponse()
    let bCallEnv = try JSONDecoder().decode(RPCEnvelope.self, from: Data(bCall.utf8))
    #expect(bCallEnv.id == 7)
    #expect(try extractEchoedPattern(from: bCallEnv) == "buffered-B")
  }

  /// When the bridge emits `notifications/progress`, the router maps the
  /// progressToken back through `progressMap` and delivers it to the
  /// originating client only — even when two clients used the same
  /// client-side token.
  @Test func progressNotificationRoutesToOrigin() async throws {
    let (router, connection, a, b) = startSharedRouter()
    defer { Task { await connection.terminate() } }

    initializeClient(router, id: a.id)
    initializeClient(router, id: b.id)
    _ = try await a.responses.nextResponse()
    _ = try await b.responses.nextResponse()

    // Both clients call __emit_progress with the same client-side
    // progressToken (7). The mock echoes each request's (rewritten)
    // token back as a progress notification before the final response.
    router.handleClientMessage(
      from: a.id,
      #"{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"__emit_progress","arguments":{},"_meta":{"progressToken":7}}}"#,
    )
    router.handleClientMessage(
      from: b.id,
      #"{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"__emit_progress","arguments":{},"_meta":{"progressToken":7}}}"#,
    )

    try await assertProgressThenResult(a.responses, expectedToken: 7, expectedResponseId: 20)
    try await assertProgressThenResult(b.responses, expectedToken: 7, expectedResponseId: 20)
  }

  /// Server-initiated notifications that lack a routing correlation (no
  /// response id and no progressToken — e.g. `tools/list_changed`) are
  /// broadcast to every connected client.
  @Test func listChangedNotificationBroadcasts() async throws {
    let (router, connection, a, b) = startSharedRouter()
    defer { Task { await connection.terminate() } }

    initializeClient(router, id: a.id)
    initializeClient(router, id: b.id)
    _ = try await a.responses.nextResponse()
    _ = try await b.responses.nextResponse()

    // A triggers a broadcast via the probe tool.
    router.handleClientMessage(
      from: a.id,
      #"{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"__emit_broadcast","arguments":{}}}"#,
    )

    // Both A and B must receive the broadcast; A additionally receives
    // its tool-call response. Order isn't fixed, so collect and classify.
    let aEvents = try await collectTwo(a.responses)
    let bEvent = try await collectOne(b.responses)

    #expect(aEvents.contains { $0.method == "notifications/tools/list_changed" })
    #expect(aEvents.contains { $0.id == 30 })
    #expect(bEvent.method == "notifications/tools/list_changed")
    #expect(bEvent.id == nil)
  }

  /// `notifications/cancelled` carries a `requestId` pointing at a prior
  /// request. The router must rewrite that field from the client's id to
  /// the bridge-facing id so mcpbridge can cancel the right call.
  @Test func cancelledRequestIdIsRewrittenForBridge() async throws {
    let (router, connection, a, _) = startSharedRouter()
    defer { Task { await connection.terminate() } }

    initializeClient(router, id: a.id)
    _ = try await a.responses.nextResponse()

    // Fire tools/call id=55 and cancel back-to-back. The cancel Task
    // processes faster than the Python subprocess round-trip, so the
    // rewrite happens while `idMap` still has the entry.
    router.handleClientMessage(
      from: a.id,
      #"{"jsonrpc":"2.0","id":55,"method":"tools/call","params":{"name":"XcodeGrep","arguments":{"pattern":"x","tabIdentifier":"t1"}}}"#,
    )
    router.handleClientMessage(
      from: a.id,
      #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":55,"reason":"test"}}"#,
    )
    _ = try await a.responses.nextResponse() // drain the XcodeGrep reply

    // Probe the mock: what requestId did it actually see for that cancel?
    router.handleClientMessage(
      from: a.id,
      #"{"jsonrpc":"2.0","id":56,"method":"tools/call","params":{"name":"__last_cancel","arguments":{}}}"#,
    )
    let raw = try await a.responses.nextResponse()
    let env = try JSONDecoder().decode(RPCEnvelope.self, from: Data(raw.utf8))
    #expect(env.id == 56)

    guard case let .object(result)? = env.rest["result"],
          case let .array(content)? = result["content"],
          case let .object(first)? = content.first,
          case let .string(text)? = first["text"]
    else {
      Issue.record("unexpected shape")
      return
    }
    let probe = try JSONDecoder().decode([String: Int?].self, from: Data(text.utf8))
    let bridgeRequestId = try #require(probe["requestId"] ?? nil)
    // Key assertion: mcpbridge did NOT see the client's raw id=55.
    #expect(bridgeRequestId != 55)
  }

  // MARK: - Helpers

  private func assertProgressThenResult(
    _ collector: ResponseCollector,
    expectedToken: Int,
    expectedResponseId: Int,
  ) async throws {
    let first = try await collector.nextResponse()
    let firstEnv = try JSONDecoder().decode(RPCEnvelope.self, from: Data(first.utf8))
    #expect(firstEnv.method == "notifications/progress")

    guard case let .object(params)? = firstEnv.rest["params"],
          let token = params["progressToken"]
    else {
      Issue.record("missing progressToken")
      return
    }
    #expect(token == .number(Decimal(expectedToken)))

    let second = try await collector.nextResponse()
    let secondEnv = try JSONDecoder().decode(RPCEnvelope.self, from: Data(second.utf8))
    #expect(secondEnv.id == .number(Decimal(expectedResponseId)))
  }

  private func collectTwo(_ collector: ResponseCollector) async throws -> [RPCEnvelope] {
    let a = try await collector.nextResponse()
    let b = try await collector.nextResponse()
    return try [a, b].map {
      try JSONDecoder().decode(RPCEnvelope.self, from: Data($0.utf8))
    }
  }

  private func collectOne(_ collector: ResponseCollector) async throws -> RPCEnvelope {
    let raw = try await collector.nextResponse()
    return try JSONDecoder().decode(RPCEnvelope.self, from: Data(raw.utf8))
  }

  private func extractEchoedPattern(from envelope: RPCEnvelope) throws -> String {
    guard case let .object(result)? = envelope.rest["result"],
          case let .array(content)? = result["content"],
          case let .object(first)? = content.first,
          case let .string(text)? = first["text"]
    else {
      throw ExtractError.badShape
    }
    let echoed = try JSONDecoder().decode(
      RPCEnvelope.self, from: Data(text.utf8),
    )
    guard case let .object(args)? = echoed.rest["arguments"],
          case let .string(pattern)? = args["pattern"]
    else {
      throw ExtractError.badShape
    }
    return pattern
  }

  private enum ExtractError: Error { case badShape }
}
