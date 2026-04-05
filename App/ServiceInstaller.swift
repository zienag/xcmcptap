import Darwin.C
import class Foundation.Bundle
import class Foundation.FileHandle
import class Foundation.FileManager
import class Foundation.Process
import func Foundation.NSHomeDirectory
import struct Foundation.URL
import XcodeMCPTapShared

enum ServiceInstaller {
  private static let uid = getuid()
  static let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(MCPTap.serviceName).plist"
  static let clientLinkPath = NSHomeDirectory() + "/.local/bin/xcmcptap"

  static func install() {
    guard Bundle.main.bundlePath.hasSuffix(".app") else {
      fputs("Run from the .app bundle to install.\n", stderr)
      return
    }

    let servicePath = Bundle.main.executableURL!
      .deletingLastPathComponent()
      .appendingPathComponent("xcmcptapd").path
    let clientPath = Bundle.main.executableURL!
      .deletingLastPathComponent()
      .appendingPathComponent("xcmcptap").path
    let logPath = NSHomeDirectory() + "/Library/Logs/\(MCPTap.serviceName).log"

    // Bootout old service if running
    run("/bin/launchctl", "bootout", "gui/\(uid)/\(MCPTap.serviceName)")

    // Write LaunchAgent plist
    let plist = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>\(MCPTap.serviceName)</string>
        <key>ProgramArguments</key>
        <array>
          <string>\(servicePath)</string>
        </array>
        <key>MachServices</key>
        <dict>
          <key>\(MCPTap.serviceName)</key>
          <true/>
          <key>\(MCPTap.statusServiceName)</key>
          <true/>
        </dict>
        <key>StandardOutPath</key>
        <string>\(logPath)</string>
        <key>StandardErrorPath</key>
        <string>\(logPath)</string>
      </dict>
      </plist>
      """

    do {
      try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
    } catch {
      fputs("Failed to write LaunchAgent: \(error)\n", stderr)
      return
    }

    // Register and start
    run("/bin/launchctl", "bootstrap", "gui/\(uid)", plistPath)
    run("/bin/launchctl", "kickstart", "gui/\(uid)/\(MCPTap.serviceName)")

    // Symlink client
    let linkDir = URL(fileURLWithPath: clientLinkPath).deletingLastPathComponent().path
    try? FileManager.default.createDirectory(atPath: linkDir, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: clientLinkPath)
    try? FileManager.default.createSymbolicLink(atPath: clientLinkPath, withDestinationPath: clientPath)
  }

  static func uninstall() {
    run("/bin/launchctl", "bootout", "gui/\(uid)/\(MCPTap.serviceName)")
    try? FileManager.default.removeItem(atPath: plistPath)
    try? FileManager.default.removeItem(atPath: clientLinkPath)
  }

  // MARK: - Private

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
