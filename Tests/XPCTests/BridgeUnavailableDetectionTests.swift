import AppKit
import struct Foundation.Notification
import class Foundation.NotificationCenter
import Synchronization
import Testing
import XcodeMCPTapService
import XcodeMCPTapShared

/// Exercises the two pathways the router uses to proactively detect
/// an unavailable mcpbridge without waiting for the next client tool
/// call: (1) an NSWorkspace termination notification that Xcode quit,
/// and (2) a periodic health ping that times out because mcpbridge
/// is alive but no longer responding.
///
/// Both pathways are driven here with minimal mocks:
///   - NSWorkspace is replaced by a private `NotificationCenter` the
///     test posts into directly.
///   - Real time is replaced by `ManualSleeper`, so the test tells
///     the router exactly how much wall-clock time has elapsed.
///
/// The subprocess mock (`scripts/mock-mcpbridge.py`) stays real — it's
/// already a minimal test double with a `hang-after-init` mode, and
/// mocking the MCPConnection layer further would need a substantial
/// protocol refactor for little extra coverage.
@Suite(.serialized)
struct BridgeUnavailableDetectionTests {
  static let mockBridge = MockBridge.path()

  // MARK: - XcodeLifecycleMonitor

  /// Posting a notification that the matcher accepts must fire the
  /// corresponding callback exactly once.
  @Test func monitorFiresTerminatedCallbackForMatchingNotification() async {
    let center = NotificationCenter()
    let terminated = Counter()
    let launched = Counter()

    let monitor = XcodeLifecycleMonitor(
      center: center,
      isXcode: { _ in true },
      onTerminated: { terminated.increment() },
      onLaunched: { launched.increment() },
    )

    center.post(
      name: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
    )

    #expect(terminated.value == 1)
    #expect(launched.value == 0)
    _ = monitor
  }

  /// The matcher gates the callback — a non-Xcode termination (Safari,
  /// Chrome, anything) must be ignored.
  @Test func monitorIgnoresNonMatchingNotifications() async {
    let center = NotificationCenter()
    let terminated = Counter()

    let monitor = XcodeLifecycleMonitor(
      center: center,
      isXcode: { notification in
        (notification.userInfo?["bundle"] as? String) == XcodeLifecycleMonitor.xcodeBundleID
      },
      onTerminated: { terminated.increment() },
    )

    center.post(
      name: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      userInfo: ["bundle": "com.apple.Safari"],
    )

    #expect(terminated.value == 0)
    _ = monitor
  }

  /// End-to-end: fire a fake termination notification on a private
  /// NotificationCenter, verify the router transitions through
  /// `.ready` → `.failed` without waiting for any real subprocess
  /// crash or client tool call.
  @Test func fakeTerminationNotificationFlipsRouterToFailed() async throws {
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

    let center = NotificationCenter()
    let monitor = XcodeLifecycleMonitor(
      center: center,
      isXcode: { _ in true },
      onTerminated: {
        Task { await router.markBridgeUnavailable(reason: "Xcode not running") }
      },
    )

    center.post(
      name: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
    )

    let reason = try await recorder.waitForFailed(timeout: .seconds(2))
    #expect(reason.contains("Xcode not running"))
    _ = monitor
  }

  // MARK: - Virtual-time health ping

  /// Drive the periodic health ping with a `ManualSleeper` — no real
  /// wall-clock waits, no flaky timing. The sequence is:
  ///   1. Boot router, wait for `.ready`. At this point the ping loop
  ///      has parked on `sleeper(interval)`.
  ///   2. Advance past `interval`. The ping sends `tools/list`, which
  ///      the hang-mode mock silently swallows. The loop then parks
  ///      on `sleeper(timeout)`.
  ///   3. Advance past `timeout`. The race resolves as "not completed",
  ///      the router publishes `.failed(reason: …not responding…)`.
  @Test func pingWithManualClockFlipsBridgeToFailed() async throws {
    let sleeper = ManualSleeper()
    let recorder = StatusRecorder()
    let router = MCPRouter(
      makeConnection: {
        MCPConnection(
          exec: "/usr/bin/python3",
          args: ["-u", Self.mockBridge, "--fail", "hang-after-init"],
        )
      },
      healthPingInterval: .seconds(30),
      healthPingTimeout: .seconds(10),
      sleeper: { duration in await sleeper.sleep(for: duration) },
    )
    router.onBridgeStateChanged = { recorder.append($0) }
    defer { Task { await router.shutdown() } }
    router.start()
    try await recorder.waitFor(.ready, timeout: .seconds(5))

    // Ping loop has reached `sleeper(interval)` — if it hadn't, we'd
    // advance time into a hole and race the production code to its
    // next park. Waiting for it makes the test deterministic.
    await sleeper.waitForPendingSleepers(count: 1)
    sleeper.advance(by: .seconds(30))

    // The ping now sends tools/list (hangs) and parks on
    // `sleeper(healthPingTimeout)`. Wait for that second park point.
    await sleeper.waitForPendingSleepers(count: 1)
    sleeper.advance(by: .seconds(10))

    let reason = try await recorder.waitForFailed(timeout: .seconds(2))
    #expect(reason.lowercased().contains("not responding"))
  }
}

/// Tiny thread-safe counter used by the NSWorkspace matcher tests to
/// verify the callback fires the expected number of times without
/// pulling in LockIsolated from the TCA test target.
private final class Counter: Sendable {
  private let state = Mutex(0)

  func increment() {
    state.withLock { $0 += 1 }
  }

  var value: Int {
    state.withLock { $0 }
  }
}
