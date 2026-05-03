import struct Foundation.Data
import struct Foundation.Decimal
import class Foundation.JSONDecoder
import struct Foundation.UUID
import Synchronization
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

/// When the mcpbridge subprocess fails (Xcode wasn't running yet, mcpbridge
/// crashed, TCC revoked, …), the user must NOT have to restart the service
/// by hand. Recovery is driven explicitly by the agent calling the
/// `xcmcptap_reload` fallback tool — once the bridge comes back, the
/// proxy emits `tools/list_changed` so the host re-fetches and sees the
/// real Xcode tools again.
///
/// The detailed reload contract (response shape, list_changed broadcast)
/// is pinned in `FallbackToolTests`. This suite is the integration check
/// that the full failure → reload → ready cycle stays consistent across
/// repeated attempts and surfaces the expected real tool set at the end.
@Suite(.serialized)
struct BridgeRecoveryTests {
  static let mockBridge = MockBridge.path()

  /// First boot attempt hits a bridge that dies at startup (Xcode not
  /// running). The client gets a fallback init reply and fallback tool
  /// list. Then — simulating the user launching Xcode — the factory
  /// starts returning healthy bridges, and the agent calls
  /// `xcmcptap_reload`. After that, `tools/list` must return the real
  /// Xcode tool set.
  @Test func bridgeRecoversAfterReloadCall() async throws {
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

    // 1. initialize — bridge dies at startup, client sees synthetic init.
    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(MCPProtocol.version)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
    )
    let init1 = try await nextEnvelope(collector)
    #expect(init1.id == .number(Decimal(1)))
    #expect(init1.rest["error"] == nil)
    let result1 = try init1.decodeResult(as: InitializeResult.self)
    #expect(result1.serverInfo.name == "xcmcptap")

    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
    )

    // 2. tools/list — returns fallback tools while bridge is dead.
    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
    )
    let list1 = try await nextEnvelope(collector)
    let names1 = try list1.decodeResult(as: ListToolsResult.self).tools.map(\.name)
    #expect(Set(names1) == ["xcmcptap_status", "xcmcptap_reload"])

    // 3. xcmcptap_reload — second-attempt factory returns a healthy
    //    bridge. Two messages must arrive (in either order): the
    //    reload tool result and the tools/list_changed broadcast.
    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"xcmcptap_reload","arguments":{}}}"#,
    )
    var sawReloadReply = false
    for _ in 0 ..< 2 {
      let env = try await nextEnvelope(collector, timeout: .seconds(10))
      if env.id == .number(Decimal(3)) { sawReloadReply = true }
    }
    #expect(sawReloadReply)

    // 4. tools/list now returns the real Xcode tool set.
    router.handleClientMessage(
      from: clientID,
      #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#,
    )
    let list2 = try await nextEnvelope(collector)
    let names2 = try list2.decodeResult(as: ListToolsResult.self).tools.map(\.name)
    #expect(names2.contains("BuildProject"))
    #expect(names2.contains("XcodeListWindows"))
    #expect(!names2.contains("xcmcptap_status"))
  }

  // MARK: - Helpers

  private func nextEnvelope(
    _ collector: ResponseCollector,
    timeout: Duration = .seconds(5),
  ) async throws -> RPCEnvelope {
    let line = try await collector.nextResponse(timeout: timeout)
    return try JSONDecoder().decode(RPCEnvelope.self, from: Data(line.utf8))
  }
}

/// Thread-safe incrementing counter for test factories.
final class AttemptCounter: Sendable {
  private let value = Mutex(0)
  func next() -> Int {
    value.withLock {
      $0 += 1
      return $0
    }
  }
}
