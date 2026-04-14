import struct Foundation.Data
import struct Foundation.Decimal
import class Foundation.JSONDecoder
import class Foundation.NSLock
import struct Foundation.UUID
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

/// When the mcpbridge subprocess fails (Xcode wasn't running yet, mcpbridge
/// crashed, TCC revoked, …), the user must NOT have to restart the service
/// by hand. The router auto-recovers: a new client message after a failure
/// respawns the bridge. Nothing else needs to detect Xcode startup — the
/// next client request drives the retry naturally.
@Suite(.serialized)
struct BridgeRecoveryTests {
  static let mockBridge = MockBridge.path()

  /// First boot attempt hits a bridge that dies at startup (Xcode not
  /// running). The client gets an error for its first request. Then —
  /// simulating the user launching Xcode — the factory starts returning
  /// healthy bridges. The next client request must drive a respawn and
  /// succeed without any external kick.
  @Test func bridgeRecoversAfterFailureOnNextRequest() async throws {
    let attempts = AttemptCounter()
    let factory: @Sendable () -> MCPConnection = {
      let n = attempts.next()
      let failMode = n == 1 ? "at-startup" : "normal"
      return MCPConnection(
        exec: "/usr/bin/python3",
        args: ["-u", Self.mockBridge, "--fail", failMode],
      )
    }

    let router = MCPRouter(makeConnection: factory)
    let collector = ResponseCollector()
    let clientID = router.registerClient { [collector] line in
      collector.continuation.yield(line)
    }
    router.start()
    defer { Task { await router.shutdown() } }

    // Attempt 1 — bridge dies at startup, client sees error.
    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(MCPProtocol.version)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
    )
    let first = try await collector.nextResponse()
    let firstEnv = try JSONDecoder().decode(RPCEnvelope.self, from: Data(first.utf8))
    #expect(firstEnv.id == .number(Decimal(1)))
    #expect(firstEnv.rest["error"] != nil, "first attempt should error")

    // Attempt 2 — factory now returns a healthy bridge. The client's
    // initialize must drive a respawn and succeed with a cached init.
    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"\#(MCPProtocol.version)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
    )
    let second = try await collector.nextResponse(timeout: .seconds(5))
    let secondEnv = try JSONDecoder().decode(RPCEnvelope.self, from: Data(second.utf8))
    #expect(secondEnv.id == .number(Decimal(2)))
    #expect(secondEnv.rest["error"] == nil, "second attempt should succeed")
    let result = try secondEnv.decodeResult(as: InitializeResult.self)
    #expect(result.serverInfo.name == "xcode-tools")

    // Follow-up tools/list against the live bridge should also work.
    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
    )
    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#,
    )
    let third = try await collector.nextResponse()
    let thirdEnv = try JSONDecoder().decode(RPCEnvelope.self, from: Data(third.utf8))
    #expect(thirdEnv.id == .number(Decimal(3)))
    let tools = try thirdEnv.decodeResult(as: ListToolsResult.self)
    #expect(!tools.tools.isEmpty)
  }
}

/// Thread-safe incrementing counter for test factories.
final class AttemptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }
}
