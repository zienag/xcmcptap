import struct Foundation.Date
import OSLog
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

/// Pins that the service-layer components emit state-transition logs
/// under the expected subsystem + category. Uses `OSLogStore` with
/// `.currentProcessIdentifier` scope to read back entries emitted by
/// in-process calls to `Logger` — no cross-process coordination needed,
/// since `MCPRouter` runs directly inside the test process via
/// `RouterHarness`.
@Suite(.serialized)
struct ServiceLoggingTests {
  static let mockBridge = MockBridge.path()

  @Test func routerLogsBridgeReadyOnSuccessfulBoot() async throws {
    let cutoff = Date()
    let h = RouterHarness.mock(bridge: Self.mockBridge)
    defer { Task { await h.terminate() } }

    _ = try await h.handshake()
    try await Task.sleep(for: .milliseconds(100))

    let entries = try routerEntries(since: cutoff)
    #expect(
      entries.contains { $0.composedMessage.contains("bridge ready") },
      "Expected a 'bridge ready' notice; got \(entries.map(\.composedMessage))",
    )
  }

  @Test func routerLogsBridgeFailedReasonOnBootFailure() async throws {
    let cutoff = Date()
    let h = RouterHarness(
      exec: "/usr/bin/python3", "-u", Self.mockBridge, "--fail", "at-startup",
    )
    defer { Task { await h.terminate() } }

    h.sendInitialize(id: 1)
    _ = try await h.nextResponse()
    try await Task.sleep(for: .milliseconds(100))

    let entries = try routerEntries(since: cutoff)
    #expect(
      entries.contains { $0.composedMessage.contains("bridge failed") },
      "Expected a 'bridge failed' entry; got \(entries.map(\.composedMessage))",
    )
  }

  private func routerEntries(since cutoff: Date) throws -> [OSLogEntryLog] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let position = store.position(date: cutoff)
    return try store.getEntries(at: position)
      .compactMap { $0 as? OSLogEntryLog }
      .filter { $0.subsystem == MCPTap.serviceName && $0.category == "router" }
  }
}
