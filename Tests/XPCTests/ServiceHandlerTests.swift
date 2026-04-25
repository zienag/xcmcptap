import struct Foundation.UUID
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

@Suite
struct ServiceHandlerTests {
  @Test func handlerPropagatesClientPIDIntoRegistry() throws {
    let registry = ConnectionRegistry()
    // Router with a no-op factory: we never call `start()`, so the bridge
    // stays in `.booting` and the client message is queued. That's enough
    // to exercise the registry update — we don't need a live bridge to
    // verify the PID path.
    let router = MCPRouter(makeConnection: {
      MCPConnection(exec: "/usr/bin/true")
    })
    let id = UUID()
    _ = registry.register(id: id, clientPID: 0)

    ServiceMain.handleIncomingMessage(
      MCPLine("payload", clientPID: 54_321),
      from: id,
      registry: registry,
      router: router,
    )

    let info = try #require(registry.status().connections.first)
    #expect(info.clientPID == 54_321)
    #expect(info.messagesRouted == 1)
  }

  @Test func handlerLeavesClientPIDUntouchedWhenMessageHasNone() throws {
    let registry = ConnectionRegistry()
    let router = MCPRouter(makeConnection: {
      MCPConnection(exec: "/usr/bin/true")
    })
    let id = UUID()
    _ = registry.register(id: id, clientPID: 1234)

    ServiceMain.handleIncomingMessage(
      MCPLine("payload"),
      from: id,
      registry: registry,
      router: router,
    )

    let info = try #require(registry.status().connections.first)
    #expect(info.clientPID == 1234)
  }

  @Test func handlerIgnoresZeroClientPID() throws {
    let registry = ConnectionRegistry()
    let router = MCPRouter(makeConnection: {
      MCPConnection(exec: "/usr/bin/true")
    })
    let id = UUID()
    _ = registry.register(id: id, clientPID: 1234)

    ServiceMain.handleIncomingMessage(
      MCPLine("payload", clientPID: 0),
      from: id,
      registry: registry,
      router: router,
    )

    let info = try #require(registry.status().connections.first)
    #expect(info.clientPID == 1234)
  }
}
