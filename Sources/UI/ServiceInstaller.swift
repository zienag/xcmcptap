import Darwin.C
import Dispatch
import class Foundation.Bundle
import class Foundation.FileHandle
import class Foundation.FileManager
import func Foundation.NSHomeDirectory
import class Foundation.Process
import struct Foundation.URL
import os
import ServiceManagement
import XcodeMCPTapShared
import XPC

/// Owns the install/uninstall flow for the LaunchAgent + client symlinks.
/// Identity is injected at construction so this type carries no global
/// references — production wires it up from the Xcode-generated build
/// identity, tests pass a fixture.
public struct ServiceInstaller: Sendable {
  public let identity: Identity
  private let log: Logger
  private let uid: uid_t
  private let systemSymlinkInstaller: SystemSymlinkInstaller

  public init(identity: Identity) {
    self.identity = identity
    self.log = Logger(subsystem: identity.serviceName, category: "install")
    self.uid = getuid()
    self.systemSymlinkInstaller = SystemSymlinkInstaller.live(
      helperServiceName: identity.helperServiceName,
      helperPlistName: identity.helperPlistName,
    )
  }

  /// Absolute path to the proxy binary shipped inside the running .app
  /// bundle. Used as a fallback in integration snippets when no PATH-resident
  /// symlink (brew or `/usr/local/bin`) exists.
  public var bundledClientPath: String {
    Bundle.main.executableURL?
      .deletingLastPathComponent()
      .appendingPathComponent(identity.symlinkName).path ?? ""
  }

  /// Path to the legacy `~/.local/bin/<name>` symlink. We no longer create
  /// this — brew's `binary` stanza owns the user's PATH — but `uninstall()`
  /// still removes it for users upgrading from older versions that did.
  private var legacyClientLinkPath: String {
    NSHomeDirectory() + "/.local/bin/" + identity.symlinkName
  }

  public var systemLinkPath: String {
    "/usr/local/bin/" + identity.symlinkName
  }

  public var systemLinkName: String { identity.symlinkName }

  /// Path to the bundled plist we register with SMAppService. Points
  /// inside the running .app bundle.
  public var plistPath: String {
    Bundle.main.bundleURL
      .appendingPathComponent("Contents/Library/LaunchAgents/\(identity.agentPlistName)")
      .path
  }

  private var legacyPlistPath: String {
    NSHomeDirectory() + "/Library/LaunchAgents/\(identity.agentPlistName)"
  }

  private var agentService: SMAppService {
    SMAppService.agent(plistName: identity.agentPlistName)
  }

  private var helperDaemonService: SMAppService {
    SMAppService.daemon(plistName: identity.helperPlistName)
  }

  public func isInstalled() -> Bool {
    switch agentService.status {
    case .enabled, .requiresApproval:
      return true
    case .notRegistered, .notFound:
      return false
    @unknown default:
      return false
    }
  }

  public func requiresApproval() -> Bool {
    agentService.status == .requiresApproval
  }

  public func openLoginItems() {
    SMAppService.openSystemSettingsLoginItems()
  }

  public func isOnSystemPath() -> Bool {
    Self.isReachableViaPath(symlinkName: identity.symlinkName) { path in
      (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }
  }

  /// Pure helper: returns true if `symlinkName` resolves on a PATH directory
  /// we know about. Checks brew's Apple-Silicon prefix first (`/opt/homebrew/bin`),
  /// then the legacy `/usr/local/bin` (also brew's Intel prefix). The
  /// `fileExists` predicate is injected so tests can pin behaviour without
  /// touching the real filesystem.
  public static func isReachableViaPath(
    symlinkName: String,
    fileExists: (String) -> Bool,
  ) -> Bool {
    let candidates = [
      "/opt/homebrew/bin/\(symlinkName)",
      "/usr/local/bin/\(symlinkName)",
    ]
    return candidates.contains(where: fileExists)
  }

  public func install() {
    guard Bundle.main.bundlePath.hasSuffix(".app") else {
      log.error("refusing to install: not running from a .app bundle")
      return
    }

    guard Bundle.main.executableURL != nil else {
      log.error("refusing to install: main bundle has no executable URL")
      return
    }

    // Refuse to call SMAppService when the running .app has been deleted
    // from disk (e.g. user trashed the bundle while the process kept
    // running, or a sibling install replaced it). `SMAppService.register`
    // walks the bundle on disk to load the plist; with the bundle gone,
    // it crashes inside `_load_plist_from_bundle` instead of returning an
    // error. Bail before letting the framework dereference NULL.
    guard FileManager.default.fileExists(atPath: Bundle.main.bundlePath) else {
      log.error("refusing to install: .app bundle is no longer on disk at \(Bundle.main.bundlePath, privacy: .public)")
      return
    }
    guard FileManager.default.fileExists(atPath: plistPath) else {
      log.error("refusing to install: agent plist missing at \(plistPath, privacy: .public)")
      return
    }

    cleanUpLegacyAgent()

    do {
      try agentService.register()
    } catch {
      log.error("SMAppService register failed: \(String(describing: error), privacy: .public)")
      return
    }

    log.notice("install complete")
  }

  public func uninstall() {
    // Tear down system symlink + helper daemon before the main agent so the
    // helper still has a live Mach service connection to receive the remove
    // request.
    if isOnSystemPath() {
      uninstallSystemSymlink()
    }

    do {
      try agentService.unregister()
    } catch {
      log.error("SMAppService unregister failed: \(String(describing: error), privacy: .public)")
    }

    cleanUpLegacyAgent()
    // Legacy: older versions auto-created `~/.local/bin/<name>` on first
    // launch. We don't create it anymore (brew's `binary` stanza owns PATH),
    // but clean up any stale copy left behind by an earlier install.
    try? FileManager.default.removeItem(atPath: legacyClientLinkPath)
    log.notice("uninstall complete")
  }

  /// Installs a symlink at `/usr/local/bin/<symlinkName>`. Registers a
  /// privileged helper daemon on first use — triggers one admin prompt.
  public func installSystemSymlink() {
    guard Bundle.main.bundlePath.hasSuffix(".app") else {
      log.error("refusing to install system symlink: not running from a .app bundle")
      return
    }
    guard let executableURL = Bundle.main.executableURL else {
      log.error("refusing to install system symlink: main bundle has no executable URL")
      return
    }
    // Same defensive check as `install()` — see comment there. The helper
    // daemon path also calls SMAppService, which crashes on a missing bundle.
    guard FileManager.default.fileExists(atPath: Bundle.main.bundlePath) else {
      log.error("refusing to install system symlink: .app bundle is no longer on disk at \(Bundle.main.bundlePath, privacy: .public)")
      return
    }
    let helperPlistFile = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Library/LaunchDaemons/\(identity.helperPlistName)")
      .path
    guard FileManager.default.fileExists(atPath: helperPlistFile) else {
      log.error("refusing to install system symlink: helper plist missing at \(helperPlistFile, privacy: .public)")
      return
    }
    let clientPath = executableURL
      .deletingLastPathComponent()
      .appendingPathComponent(identity.symlinkName).path

    runHelperFlow { installer in
      try await installer.install(source: clientPath)
    }
  }

  /// Removes the `/usr/local/bin/<symlinkName>` symlink via the helper daemon.
  public func uninstallSystemSymlink() {
    runHelperFlow { installer in
      try await installer.uninstall()
    }

    do {
      try helperDaemonService.unregister()
    } catch {
      log.error("SMAppService helper-daemon unregister failed: \(String(describing: error), privacy: .public)")
    }
  }

  private func runHelperFlow(
    _ operation: @Sendable @escaping (SystemSymlinkInstaller) async throws -> HelperResponse,
  ) {
    let installer = systemSymlinkInstaller
    let log = log
    let semaphore = DispatchSemaphore(value: 0)

    Task {
      defer { semaphore.signal() }
      do {
        let response = try await operation(installer)
        if case let .failure(reason) = response {
          log.error("helper returned failure: \(reason, privacy: .public)")
        }
      } catch SystemSymlinkInstallerError.requiresApproval {
        // Daemon is registered but user has to flip the switch in System Settings.
        // Open the pane so they know where to go.
        log.notice("helper daemon requires approval in Login Items")
        SMAppService.openSystemSettingsLoginItems()
      } catch {
        log.error("helper flow error: \(String(describing: error), privacy: .public)")
      }
    }

    semaphore.wait()
  }

  /// Removes any LaunchAgent installed by the pre-SMAppService code path so a fresh
  /// install doesn't leave two copies of the service registered.
  private func cleanUpLegacyAgent() {
    if FileManager.default.fileExists(atPath: legacyPlistPath) {
      run("/bin/launchctl", "bootout", "gui/\(uid)/\(identity.serviceName)")
      try? FileManager.default.removeItem(atPath: legacyPlistPath)
    }
  }

  private func run(_ path: String, _ args: String...) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }
}
