import Synchronization
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

/// Pins that the router publishes BridgeStatus transitions to the UI layer.
/// Without these events, the Overview pane's mcpbridge indicator would stay
/// stuck on `.booting` even after the subprocess succeeded or failed.
@Suite(.serialized)
struct BridgeStatusEventTests {
  static let mockBridge = MockBridge.path()

  /// Healthy boot must transition booting → ready. The callback is expected
  /// to fire exactly once with `.ready` (the initial `.booting` is the
  /// default state, not a transition).
  @Test func healthyBootTransitionsToReady() async throws {
    let recorder = StatusRecorder()
    let router = MCPRouter(
      makeConnection: {
        MCPConnection(exec: "/usr/bin/python3", args: ["-u", Self.mockBridge])
      },
    )
    router.onBridgeStateChanged = { recorder.append($0) }
    defer { Task { await router.shutdown() } }

    router.start()
    try await recorder.waitFor(.ready, timeout: .seconds(5))
    #expect(recorder.all().contains(.ready))
  }

  /// When mcpbridge dies at startup the router must publish a `.failed`
  /// event so the UI can reflect the crash. `reason` must be non-empty.
  @Test func startupFailureTransitionsToFailed() async throws {
    let recorder = StatusRecorder()
    let router = MCPRouter(
      makeConnection: {
        MCPConnection(
          exec: "/usr/bin/python3",
          args: ["-u", Self.mockBridge, "--fail", "at-startup"],
        )
      },
    )
    router.onBridgeStateChanged = { recorder.append($0) }
    defer { Task { await router.shutdown() } }

    router.start()
    let observed = try await recorder.waitForFailed(timeout: .seconds(5))
    #expect(!observed.isEmpty)
  }

  /// mcpbridge stays alive when Xcode quits but stops responding — this
  /// is the common "closed Xcode, UI still says ready" failure mode.
  /// The periodic health ping must detect the hang within the ping
  /// timeout and flip the bridge to `.failed` on its own, without
  /// waiting for a client tool-call to finally trigger detection.
  @Test func periodicPingDetectsHangingBridge() async throws {
    let recorder = StatusRecorder()
    let router = MCPRouter(
      makeConnection: {
        MCPConnection(
          exec: "/usr/bin/python3",
          args: ["-u", Self.mockBridge, "--fail", "hang-after-init"],
        )
      },
      healthPingInterval: .milliseconds(200),
      healthPingTimeout: .milliseconds(400),
    )
    router.onBridgeStateChanged = { recorder.append($0) }
    defer { Task { await router.shutdown() } }

    router.start()
    try await recorder.waitFor(.ready, timeout: .seconds(5))

    let reason = try await recorder.waitForFailed(timeout: .seconds(5))
    #expect(
      reason.lowercased().contains("ping") || reason.lowercased().contains("responding"),
      "failure reason should mention the ping; got \(reason)",
    )
  }

  /// External trigger (e.g. NSWorkspace notification that Xcode quit, or
  /// a health-check timeout) must be able to flip the router to
  /// `.failed` without waiting for the next client message or subprocess
  /// crash. Recovery still happens on the next client message via the
  /// existing auto-respawn path.
  @Test func markBridgeUnavailableForcesFailedTransition() async throws {
    let recorder = StatusRecorder()
    let router = MCPRouter(
      makeConnection: {
        MCPConnection(exec: "/usr/bin/python3", args: ["-u", Self.mockBridge])
      },
    )
    router.onBridgeStateChanged = { recorder.append($0) }
    defer { Task { await router.shutdown() } }

    router.start()
    try await recorder.waitFor(.ready, timeout: .seconds(5))

    router.markBridgeUnavailable(reason: "Xcode not running")

    let reason = try await recorder.waitForFailed(timeout: .seconds(2))
    #expect(reason.contains("Xcode not running"))
  }
}

final class StatusRecorder: Sendable {
  private struct State {
    var events: [BridgeStatus] = []
    var subscribers: [AsyncStream<BridgeStatus>.Continuation] = []
  }

  private let state = Mutex(State())

  func append(_ status: BridgeStatus) {
    let subscribers = state.withLock { s -> [AsyncStream<BridgeStatus>.Continuation] in
      s.events.append(status)
      return s.subscribers
    }
    for subscriber in subscribers { subscriber.yield(status) }
  }

  func all() -> [BridgeStatus] {
    state.withLock { $0.events }
  }

  private func subscribe() -> AsyncStream<BridgeStatus> {
    AsyncStream { continuation in
      state.withLock { s in
        for event in s.events { continuation.yield(event) }
        s.subscribers.append(continuation)
      }
    }
  }

  func waitFor(
    _ target: BridgeStatus,
    timeout: Duration,
  ) async throws {
    let matched: Bool? = await raceTimeout(timeout) {
      for await status in self.subscribe() where status == target { return true }
      return nil
    }
    if matched != true {
      Issue.record("timed out waiting for \(target); got \(all())")
    }
  }

  func waitForFailed(timeout: Duration) async throws -> String {
    let reason: String? = await raceTimeout(timeout) {
      for await status in self.subscribe() {
        if case let .failed(reason) = status { return reason }
      }
      return nil
    }
    if let reason { return reason }
    Issue.record("timed out waiting for .failed; got \(all())")
    return ""
  }
}

private func raceTimeout<T: Sendable>(
  _ duration: Duration,
  _ work: @Sendable @escaping () async -> T?,
) async -> T? {
  await withTaskGroup(of: T?.self) { group in
    group.addTask { await work() }
    group.addTask {
      try? await Task.sleep(for: duration)
      return nil
    }
    let result = await group.next() ?? nil
    group.cancelAll()
    return result
  }
}
