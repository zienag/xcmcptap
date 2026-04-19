import AppKit
import Foundation

/// Observes NSWorkspace notifications for Xcode lifecycle events.
/// Exists to let the router proactively flip the bridge to `.failed`
/// when the user quits Xcode — the mcpbridge subprocess itself often
/// stays alive and just hangs, so without this hook the UI would
/// keep showing "mcpbridge ready" until the next tool call finally
/// surfaces the failure.
///
/// The `NotificationCenter`, notification names, and the "is this
/// Xcode?" matcher closure are all injectable so tests can drive the
/// observer with fake notifications on a private center — no need to
/// poke real NSWorkspace to exercise the callback.
public final class XcodeLifecycleMonitor {
  public static let xcodeBundleID = "com.apple.dt.Xcode"

  /// Production matcher: unpacks `NSRunningApplication` from the
  /// NSWorkspace notification user-info and checks bundle id.
  public static let defaultIsXcode: @Sendable (Notification) -> Bool = { notification in
    guard
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
      as? NSRunningApplication
    else { return false }
    return app.bundleIdentifier == xcodeBundleID
  }

  private let center: NotificationCenter
  private let terminateObserver: any NSObjectProtocol
  private let launchObserver: any NSObjectProtocol

  /// Creates and installs observers. Keep the returned instance alive
  /// for the lifetime of the service — releasing it removes the
  /// observers. Defaults target real NSWorkspace; tests inject a
  /// private NotificationCenter + permissive matcher.
  public init(
    center: NotificationCenter = NSWorkspace.shared.notificationCenter,
    terminatedName: Notification.Name = NSWorkspace.didTerminateApplicationNotification,
    launchedName: Notification.Name = NSWorkspace.didLaunchApplicationNotification,
    isXcode: @escaping @Sendable (Notification) -> Bool = defaultIsXcode,
    onTerminated: @escaping @Sendable () -> Void,
    onLaunched: @escaping @Sendable () -> Void = {},
  ) {
    self.center = center
    terminateObserver = center.addObserver(
      forName: terminatedName,
      object: nil,
      queue: nil,
    ) { [isXcode, onTerminated] notification in
      guard isXcode(notification) else { return }
      onTerminated()
    }
    launchObserver = center.addObserver(
      forName: launchedName,
      object: nil,
      queue: nil,
    ) { [isXcode, onLaunched] notification in
      guard isXcode(notification) else { return }
      onLaunched()
    }
  }

  /// Whether Xcode is currently running. Useful at startup to decide
  /// the initial bridge state before the first client request arrives.
  public static var isXcodeRunning: Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == xcodeBundleID }
  }

  deinit {
    center.removeObserver(terminateObserver)
    center.removeObserver(launchObserver)
  }
}
