import Foundation
import Testing
import XcodeMCPTapShared
import XPC

@Suite(.serialized)
struct HelperEndToEndTests {
  static let serviceName = "alfred.xcmcptap.test-helper"
  static let destination = NSHomeDirectory() + "/.xcmcptap-test-helper-link"

  init() throws {
    try Self.ensureHelperRunning()
    try? FileManager.default.removeItem(atPath: Self.destination)
  }

  @Test
  func installSymlinkCreatesLinkThenRemoveDeletesIt() throws {
    let session = try makeSession()
    defer { session.cancel(reason: "test done") }

    let source = try makeSource()

    let installResponse: HelperResponse = try session.sendSync(
      HelperRequest.installSymlink(sourcePath: source),
    )
    #expect(installResponse == .success)

    let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: Self.destination)
    #expect(resolved == source)

    let removeResponse: HelperResponse = try session.sendSync(HelperRequest.removeSymlink)
    #expect(removeResponse == .success)
    #expect(!FileManager.default.fileExists(atPath: Self.destination))
  }

  @Test
  func statusReturnsSuccess() throws {
    let session = try makeSession()
    defer { session.cancel(reason: "test done") }

    let response: HelperResponse = try session.sendSync(HelperRequest.status)
    #expect(response == .success)
  }

  @Test
  func installIsIdempotent() throws {
    let session = try makeSession()
    defer { session.cancel(reason: "test done") }

    let source1 = try makeSource()
    let source2 = try makeSource()

    _ = try session.sendSync(HelperRequest.installSymlink(sourcePath: source1)) as HelperResponse
    let second: HelperResponse = try session.sendSync(HelperRequest.installSymlink(sourcePath: source2))

    #expect(second == .success)
    let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: Self.destination)
    #expect(resolved == source2)
  }

  // MARK: - Helpers

  private func makeSession() throws -> XPCSession {
    try XPCSession(
      machService: Self.serviceName,
      incomingMessageHandler: { (_: HelperResponse) -> (any Encodable)? in nil },
      cancellationHandler: nil,
    )
  }

  private func makeSource() throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("helper-e2e-source-\(UUID().uuidString)")
    try Data("bin".utf8).write(to: url)
    return url.path
  }

  // MARK: - Service Registration

  static func ensureHelperRunning() throws {
    // Always re-bootstrap so the plist stays in sync with the test env
    // (which evolves — e.g. env vars like HELPER_ALLOW_ANY_PEER).
    let bootout = Process()
    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootout.arguments = ["bootout", "gui/\(getuid())/\(serviceName)"]
    bootout.standardOutput = FileHandle.nullDevice
    bootout.standardError = FileHandle.nullDevice
    try? bootout.run()
    bootout.waitUntilExit()

    let helperPath = try XPCIntegrationTests.findBinaryPath("xcmcptap-helper")
    let logPath = NSHomeDirectory() + "/Library/Logs/\(serviceName).log"

    guard FileManager.default.fileExists(atPath: helperPath) else {
      throw MissingTestBinary(
        description: "xcmcptap-helper not found at \(helperPath). Run 'swift build' first.",
      )
    }

    let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(serviceName).plist"
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>\(serviceName)</string>
      <key>ProgramArguments</key>
      <array>
        <string>\(helperPath)</string>
      </array>
      <key>EnvironmentVariables</key>
      <dict>
        <key>HELPER_MACH_SERVICE</key>
        <string>\(serviceName)</string>
        <key>HELPER_DESTINATION</key>
        <string>\(destination)</string>
        <key>HELPER_ALLOW_ANY_PEER</key>
        <string>1</string>
      </dict>
      <key>MachServices</key>
      <dict>
        <key>\(serviceName)</key>
        <true/>
      </dict>
      <key>StandardOutPath</key>
      <string>\(logPath)</string>
      <key>StandardErrorPath</key>
      <string>\(logPath)</string>
    </dict>
    </plist>
    """

    try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

    let bootstrap = Process()
    bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootstrap.arguments = ["bootstrap", "gui/\(getuid())", plistPath]
    bootstrap.standardError = FileHandle.nullDevice
    try bootstrap.run()
    bootstrap.waitUntilExit()

    Thread.sleep(forTimeInterval: 0.5)
  }
}
