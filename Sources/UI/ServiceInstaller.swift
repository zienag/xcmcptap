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

private let log = Logger(subsystem: MCPTap.serviceName, category: "install")

public enum ServiceInstaller {
  private static let uid = getuid()
  private static let agentPlistName = "\(MCPTap.serviceName).plist"
  private static let helperPlistName = "\(MCPTap.helperServiceName).plist"
  private static let legacyPlistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(MCPTap.serviceName).plist"

  public static let clientLinkPath = NSHomeDirectory() + "/.local/bin/xcmcptap"
  public static let systemLinkPath = "/usr/local/bin/xcmcptap"
  public static let systemLinkName = "xcmcptap"

  /// Path to the bundled plist we register with SMAppService. Points inside the running .app bundle.
  public static var plistPath: String {
    Bundle.main.bundleURL
      .appendingPathComponent("Contents/Library/LaunchAgents/\(agentPlistName)")
      .path
  }

  private static var agentService: SMAppService {
    SMAppService.agent(plistName: agentPlistName)
  }

  private static var helperDaemonService: SMAppService {
    SMAppService.daemon(plistName: helperPlistName)
  }

  public static func isInstalled() -> Bool {
    switch agentService.status {
    case .enabled, .requiresApproval:
      return true
    case .notRegistered, .notFound:
      return false
    @unknown default:
      return false
    }
  }

  public static func requiresApproval() -> Bool {
    agentService.status == .requiresApproval
  }

  public static func openLoginItems() {
    SMAppService.openSystemSettingsLoginItems()
  }

  public static func isOnSystemPath() -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: systemLinkPath)) != nil
  }

  public static func install() {
    guard Bundle.main.bundlePath.hasSuffix(".app") else {
      log.error("refusing to install: not running from a .app bundle")
      return
    }

    let clientPath = Bundle.main.executableURL!
      .deletingLastPathComponent()
      .appendingPathComponent("xcmcptap").path

    cleanUpLegacyAgent()

    do {
      try agentService.register()
    } catch {
      log.error("SMAppService register failed: \(String(describing: error), privacy: .public)")
      return
    }

    let linkDir = URL(fileURLWithPath: clientLinkPath).deletingLastPathComponent().path
    try? FileManager.default.createDirectory(atPath: linkDir, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: clientLinkPath)
    try? FileManager.default.createSymbolicLink(atPath: clientLinkPath, withDestinationPath: clientPath)
    log.notice("install complete")
  }

  public static func uninstall() {
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
    try? FileManager.default.removeItem(atPath: clientLinkPath)
    log.notice("uninstall complete")
  }

  /// Installs a symlink at `/usr/local/bin/xcmcptap`. Registers a privileged
  /// helper daemon on first use — triggers one admin prompt.
  public static func installSystemSymlink() {
    guard Bundle.main.bundlePath.hasSuffix(".app") else {
      log.error("refusing to install system symlink: not running from a .app bundle")
      return
    }
    let clientPath = Bundle.main.executableURL!
      .deletingLastPathComponent()
      .appendingPathComponent("xcmcptap").path

    runHelperFlow { installer in
      try await installer.install(source: clientPath)
    }
  }

  /// Removes the `/usr/local/bin/xcmcptap` symlink via the helper daemon.
  public static func uninstallSystemSymlink() {
    runHelperFlow { installer in
      try await installer.uninstall()
    }

    do {
      try helperDaemonService.unregister()
    } catch {
      log.error("SMAppService helper-daemon unregister failed: \(String(describing: error), privacy: .public)")
    }
  }

  private static func runHelperFlow(
    _ operation: @Sendable @escaping (SystemSymlinkInstaller) async throws -> HelperResponse,
  ) {
    let installer = SystemSymlinkInstaller.live
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
  private static func cleanUpLegacyAgent() {
    if FileManager.default.fileExists(atPath: legacyPlistPath) {
      run("/bin/launchctl", "bootout", "gui/\(uid)/\(MCPTap.serviceName)")
      try? FileManager.default.removeItem(atPath: legacyPlistPath)
    }
  }

  private static func run(_ path: String, _ args: String...) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }
}
