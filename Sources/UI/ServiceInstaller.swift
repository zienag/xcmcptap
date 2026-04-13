import Darwin.C
import class Foundation.Bundle
import class Foundation.FileHandle
import class Foundation.FileManager
import class Foundation.Process
import func Foundation.NSHomeDirectory
import struct Foundation.URL
import ServiceManagement
import XcodeMCPTapShared

public enum ServiceInstaller {
  private static let uid = getuid()
  private static let agentPlistName = "\(MCPTap.serviceName).plist"
  private static let legacyPlistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(MCPTap.serviceName).plist"

  public static let clientLinkPath = NSHomeDirectory() + "/.local/bin/xcmcptap"
  public static let systemLinkPath = "/usr/local/bin/xcmcptap"
  public static let systemLinkName = "xcmcptap"
  public static let logPath = NSHomeDirectory() + "/Library/Logs/\(MCPTap.serviceName).log"

  /// Path to the bundled plist we register with SMAppService. Points inside the running .app bundle.
  public static var plistPath: String {
    Bundle.main.bundleURL
      .appendingPathComponent("Contents/Library/LaunchAgents/\(agentPlistName)")
      .path
  }

  private static var agentService: SMAppService {
    SMAppService.agent(plistName: agentPlistName)
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
      fputs("Run from the .app bundle to install.\n", stderr)
      return
    }

    let clientPath = Bundle.main.executableURL!
      .deletingLastPathComponent()
      .appendingPathComponent("xcmcptap").path

    cleanUpLegacyAgent()

    do {
      try agentService.register()
    } catch {
      fputs("SMAppService register failed: \(error)\n", stderr)
      return
    }

    let linkDir = URL(fileURLWithPath: clientLinkPath).deletingLastPathComponent().path
    try? FileManager.default.createDirectory(atPath: linkDir, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: clientLinkPath)
    try? FileManager.default.createSymbolicLink(atPath: clientLinkPath, withDestinationPath: clientPath)
  }

  public static func uninstall() {
    do {
      try agentService.unregister()
    } catch {
      fputs("SMAppService unregister failed: \(error)\n", stderr)
    }

    cleanUpLegacyAgent()
    try? FileManager.default.removeItem(atPath: clientLinkPath)
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
