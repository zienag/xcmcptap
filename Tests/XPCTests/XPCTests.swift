import Foundation
import Testing
import XcodeMCPTapShared
import XPC

@Suite(.serialized)
struct XPCIntegrationTests {
  static let serviceName = "alfred.xcmcptap.test-echo"

  init() throws {
    try Self.ensureEchoServerRunning()
  }

  @Test func roundTrip() throws {
    let session = try makeSession()
    defer { session.cancel(reason: "test done") }
    let reply: MCPLine = try session.sendSync(MCPLine("hello"))
    #expect(reply.content == "echo:hello")
  }

  @Test func multipleMessages() throws {
    let session = try makeSession()
    defer { session.cancel(reason: "test done") }
    for i in 0 ..< 10 {
      let reply: MCPLine = try session.sendSync(MCPLine("msg-\(i)"))
      #expect(reply.content == "echo:msg-\(i)")
    }
  }

  @Test func emptyContent() throws {
    let session = try makeSession()
    defer { session.cancel(reason: "test done") }
    let reply: MCPLine = try session.sendSync(MCPLine(""))
    #expect(reply.content == "echo:")
  }

  @Test func largePayload() throws {
    let session = try makeSession()
    defer { session.cancel(reason: "test done") }
    let large = String(repeating: "x", count: 100_000)
    let reply: MCPLine = try session.sendSync(MCPLine(large))
    #expect(reply.content == "echo:" + large)
  }

  @Test func concurrentSessions() throws {
    let session1 = try makeSession()
    let session2 = try makeSession()
    defer {
      session1.cancel(reason: "test done")
      session2.cancel(reason: "test done")
    }

    let reply1: MCPLine = try session1.sendSync(MCPLine("from-1"))
    let reply2: MCPLine = try session2.sendSync(MCPLine("from-2"))

    #expect(reply1.content == "echo:from-1")
    #expect(reply2.content == "echo:from-2")
  }

  // MARK: - Helpers

  private func makeSession() throws -> XPCSession {
    try XPCSession(
      machService: Self.serviceName,
      incomingMessageHandler: { (_: MCPLine) -> (any Encodable)? in nil },
      cancellationHandler: nil,
    )
  }

  // MARK: - Service Registration

  static func ensureEchoServerRunning() throws {
    let check = Process()
    check.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    check.arguments = ["print", "gui/\(getuid())/\(serviceName)"]
    check.standardOutput = FileHandle.nullDevice
    check.standardError = FileHandle.nullDevice
    try check.run()
    check.waitUntilExit()

    if check.terminationStatus == 0 { return }

    let echoServerPath = try findBinaryPath("xpc-test-echo-server")
    let logPath = NSHomeDirectory() + "/Library/Logs/\(serviceName).log"

    guard FileManager.default.fileExists(atPath: echoServerPath) else {
      fatalError(
        "xpc-test-echo-server not found at \(echoServerPath). Run 'swift build' first.",
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
        <string>\(echoServerPath)</string>
      </array>
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

  static let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  static func findBinaryPath(_ name: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = ["build", "--show-bin-path"]
    process.currentDirectoryURL = projectRoot

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let binDir = try #require(String(data: data, encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(binDir)/\(name)"
  }
}
