import class Foundation.FileHandle
import class Foundation.Pipe
import class Foundation.Process
import struct Foundation.Data
import struct Foundation.URL
import Dispatch
import Subprocess
import Synchronization
import System
import Testing

@Suite(.serialized)
struct SubprocessRoundTripTests {
  static let fakeMCPServer: String = {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("fake-mcp-server.py")
      .path
  }()

  static let initRequest = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#

  // Test 1: Foundation Process + Pipe baseline (known working approach)
  @Test func foundationProcessRoundTrip() throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc.arguments = ["-u", Self.fakeMCPServer]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    proc.standardInput = stdinPipe
    proc.standardOutput = stdoutPipe
    proc.standardError = FileHandle.nullDevice

    try proc.run()

    stdinPipe.fileHandleForWriting.write(Data((Self.initRequest + "\n").utf8))
    stdinPipe.fileHandleForWriting.closeFile()

    proc.waitUntilExit()

    let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""

    #expect(output.contains("fake-mcp-server"), "Foundation Process round-trip works")
  }

  // Test 2: Foundation Process + Pipe WITHOUT closing stdin (interactive, like the real bridge)
  @Test func foundationProcessInteractive() throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc.arguments = ["-u", Self.fakeMCPServer]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    proc.standardInput = stdinPipe
    proc.standardOutput = stdoutPipe
    proc.standardError = FileHandle.nullDevice

    try proc.run()

    // Write without closing stdin
    stdinPipe.fileHandleForWriting.write(Data((Self.initRequest + "\n").utf8))

    // Read with a short timeout using availableData on background thread
    nonisolated(unsafe) var output = ""
    let expectation = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      let data = stdoutPipe.fileHandleForReading.availableData
      output = String(data: data, encoding: .utf8) ?? ""
      expectation.signal()
    }
    let timedOut = expectation.wait(timeout: .now() + 5) == .timedOut

    proc.terminate()
    proc.waitUntilExit()

    #expect(!timedOut, "Should not time out waiting for response")
    #expect(output.contains("fake-mcp-server"), "Should get response without closing stdin")
  }

  // Test: mcpbridge via Foundation.Process (interactive, stdin stays open)
  @Test func mcpbridgeFoundationProcess() throws {
    let initRequest = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    proc.arguments = ["mcpbridge"]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    proc.standardInput = stdinPipe
    proc.standardOutput = stdoutPipe
    proc.standardError = FileHandle.nullDevice

    try proc.run()

    stdinPipe.fileHandleForWriting.write(Data((initRequest + "\n").utf8))

    nonisolated(unsafe) var output = ""
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      let data = stdoutPipe.fileHandleForReading.availableData
      output = String(data: data, encoding: .utf8) ?? ""
      sem.signal()
    }
    let timedOut = sem.wait(timeout: .now() + 10) == .timedOut

    proc.terminate()
    proc.waitUntilExit()

    #expect(!timedOut, "mcpbridge should respond within 10s")
    #expect(output.contains("xcode-tools"), "Response should contain xcode-tools, got: \(output.prefix(200))")
  }

  // Test: mcpbridge via Foundation.Process from a DispatchQueue (simulates dispatchMain context)
  @Test func mcpbridgeFromDispatchQueue() throws {
    let initRequest = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#

    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var output = ""
    nonisolated(unsafe) var launchError: (any Error)?

    // Simulate what happens in xcmcptapd: the XPC listener accept handler
    // runs on a dispatch queue, creates Process, writes to it
    DispatchQueue.global().async {
      do {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["mcpbridge"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice

        try proc.run()

        stdinPipe.fileHandleForWriting.write(Data((initRequest + "\n").utf8))

        let data = stdoutPipe.fileHandleForReading.availableData
        output = String(data: data, encoding: .utf8) ?? ""

        proc.terminate()
        proc.waitUntilExit()
      } catch {
        launchError = error
      }
      sem.signal()
    }

    let timedOut = sem.wait(timeout: .now() + 10) == .timedOut

    #expect(launchError == nil)
    #expect(!timedOut, "Should not time out")
    #expect(output.contains("xcode-tools"), "Got: \(output.prefix(200))")
  }

  // Test: mcpbridge via Subprocess (same as Test 3 but with real mcpbridge)
  @Test func mcpbridgeViaSubprocess() async throws {
    let initRequest = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#

    let result: String? = try await run(
      .path(FilePath("/usr/bin/xcrun")),
      arguments: ["mcpbridge"],
      error: .discarded,
      preferredBufferSize: 1
    ) { execution, inputWriter, outputSequence in

      try await withThrowingTaskGroup(of: String?.self) { group in
        group.addTask {
          var payload = Data(initRequest.utf8)
          payload.append(0x0A)
          _ = try await inputWriter.write(payload)
          return nil
        }
        group.addTask {
          for try await line in outputSequence.lines() {
            return line
          }
          return nil
        }
        group.addTask {
          try await Task.sleep(for: .seconds(10))
          return nil
        }

        var firstLine: String?
        while let value = try await group.next() {
          if let v = value {
            firstLine = v
            group.cancelAll()
            break
          }
        }
        return firstLine
      }
    }.value

    #expect(result != nil, "mcpbridge should respond via Subprocess")
    #expect(result?.contains("xcode-tools") == true)
  }

  // Test 3: Subprocess 3-param with preferredBufferSize: 1 (fixes DispatchIO buffering)
  @Test func subprocessThreeParamWithSmallBuffer() async throws {
    let result: String? = try await run(
      .path(FilePath("/usr/bin/python3")),
      arguments: ["-u", Self.fakeMCPServer],
      error: .discarded,
      preferredBufferSize: 1
    ) { execution, inputWriter, outputSequence in

      try await withThrowingTaskGroup(of: String?.self) { group in
        group.addTask {
          var payload = Data(Self.initRequest.utf8)
          payload.append(0x0A)
          _ = try await inputWriter.write(payload)
          return nil
        }
        group.addTask {
          for try await line in outputSequence.lines() {
            return line
          }
          return nil
        }

        var firstLine: String?
        while let value = try await group.next() {
          if let v = value { firstLine = v }
        }
        return firstLine
      }
    }.value

    #expect(result != nil, "preferredBufferSize: 1 should deliver stdout immediately")
    #expect(result?.contains("fake-mcp-server") == true)
  }

  // Test 4: Subprocess 2-param closure with one-shot input — the README way
  @Test func subprocessTwoParamWorks() async throws {
    let inputData = Data((Self.initRequest + "\n").utf8)
    var receivedLines: [String] = []

    _ = try await run(
      .path(FilePath("/usr/bin/python3")),
      arguments: ["-u", Self.fakeMCPServer],
      input: .data(inputData),
      error: .discarded
    ) { execution, outputSequence in

      await withThrowingTaskGroup(of: String?.self) { group in
        group.addTask {
          for try await line in outputSequence.lines() {
            return line
          }
          return nil
        }
        group.addTask {
          try await Task.sleep(for: .seconds(3))
          return nil
        }
        if let result = try? await group.next(), let line = result {
          receivedLines.append(line)
        }
        group.cancelAll()
      }
    }

    #expect(!receivedLines.isEmpty, "2-param API should deliver stdout")
    if let first = receivedLines.first {
      #expect(first.contains("fake-mcp-server"), "Response should contain server name")
    }
  }

}
