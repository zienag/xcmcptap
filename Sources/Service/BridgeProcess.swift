import Darwin.C
import Subprocess
import Synchronization
import System

final class BridgeProcess: @unchecked Sendable {
  var onOutput: (@Sendable (String) -> Void)?
  var onExit: (@Sendable () -> Void)?

  private let stdinContinuation: AsyncStream<String>.Continuation
  private let stdinStream: AsyncStream<String>
  private var task: Task<Void, Never>?
  private let _processID = Mutex<pid_t>(0)

  var processID: pid_t {
    _processID.withLock { $0 }
  }

  init() {
    (stdinStream, stdinContinuation) = AsyncStream.makeStream()
  }

  func start() {
    let onOutput = onOutput
    let onExit = onExit
    let stdinStream = stdinStream

    task = Task {
      defer { onExit?() }
      do {
        _ = try await run(
          .path(FilePath("/usr/bin/xcrun")),
          arguments: ["mcpbridge"],
          error: .discarded
        ) { [self] execution, inputWriter, outputSequence in
          _processID.withLock { $0 = execution.processIdentifier.value }

          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              for await content in stdinStream {
                _ = try await inputWriter.write(content + "\n", using: UTF8.self)
              }
              try await inputWriter.finish()
            }
            group.addTask {
              for try await line in outputSequence.lines() {
                onOutput?(line)
              }
            }
            try await group.waitForAll()
          }
        }
      } catch {
        fputs("Bridge error: \(error)\n", stderr)
      }
    }
  }

  func write(_ content: String) {
    stdinContinuation.yield(content)
  }

  func terminate() {
    stdinContinuation.finish()
    task?.cancel()
  }
}
