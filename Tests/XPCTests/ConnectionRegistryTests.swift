import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import struct Foundation.UUID
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

@Suite
struct ConnectionRegistryTests {
  @Test func registerStoresClientPID() throws {
    let registry = ConnectionRegistry()
    let id = UUID()
    _ = registry.register(id: id, clientPID: 4242)
    let info = try #require(registry.status().connections.first)
    #expect(info.clientPID == 4242)
  }

  @Test func updateClientPIDReplacesPlaceholderValue() throws {
    let registry = ConnectionRegistry()
    let id = UUID()
    _ = registry.register(id: id, clientPID: 0)
    registry.updateClientPID(id: id, pid: 77_777)
    let info = try #require(registry.status().connections.first)
    #expect(info.clientPID == 77_777)
  }

  @Test func updateClientPIDIsNoOpForUnknownConnection() {
    let registry = ConnectionRegistry()
    registry.updateClientPID(id: UUID(), pid: 123)
    #expect(registry.status().connections.isEmpty)
  }

  @Test func mcpLineRoundTripsClientPID() throws {
    let line = MCPLine("hello", clientPID: 9999)
    let data = try JSONEncoder().encode(line)
    let decoded = try JSONDecoder().decode(MCPLine.self, from: data)
    #expect(decoded.content == "hello")
    #expect(decoded.clientPID == 9999)
  }

  @Test func mcpLineWithoutClientPIDDecodesToNil() throws {
    let data = try JSONEncoder().encode(MCPLine("hello"))
    let decoded = try JSONDecoder().decode(MCPLine.self, from: data)
    #expect(decoded.content == "hello")
    #expect(decoded.clientPID == nil)
  }
}
