import Darwin.C
import Subprocess
import Synchronization
import System

public final class BridgeProcess: Sendable {
  private let executablePath: String
  private let executableArgs: [String]
  private let inputStream: AsyncStream<[UInt8]>
  private let inputContinuation: AsyncStream<[UInt8]>.Continuation
  private let _processID = Mutex<pid_t>(0)
  private let _task = Mutex<Task<Void, Never>?>(nil)
  private let callbacks = Mutex(Callbacks())

  private struct Callbacks: Sendable {
    var onOutput: (@Sendable (String) -> Void)?
    var onExit: (@Sendable () -> Void)?
  }

  public var onOutput: (@Sendable (String) -> Void)? {
    get { callbacks.withLock { $0.onOutput } }
    set { callbacks.withLock { $0.onOutput = newValue } }
  }

  public var onExit: (@Sendable () -> Void)? {
    get { callbacks.withLock { $0.onExit } }
    set { callbacks.withLock { $0.onExit = newValue } }
  }

  public var processID: pid_t {
    _processID.withLock { $0 }
  }

  public init(executable: String = "/usr/bin/xcrun", arguments: [String] = ["mcpbridge"]) {
    self.executablePath = executable
    self.executableArgs = arguments
    let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
    self.inputStream = stream
    self.inputContinuation = continuation
  }

  public func start() {
    let cbs = callbacks.withLock { $0 }
    let onOutput = cbs.onOutput
    let onExit = cbs.onExit
    let inputStream = inputStream

    let task = Task.detached { [self] in
      do {
        _ = try await run(
          .path(FilePath(self.executablePath)),
          arguments: Arguments(self.executableArgs),
          error: .discarded,
          preferredBufferSize: 1
        ) { execution, inputWriter, outputSequence in
          self._processID.withLock { $0 = execution.processIdentifier.value }

          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              for await bytes in inputStream {
                _ = try await inputWriter.write(bytes)
              }
              try await inputWriter.finish()
            }

            group.addTask {
              for try await line in outputSequence.lines() {
                if !line.isEmpty {
                  onOutput?(line)
                }
              }
            }

            try await group.waitForAll()
          }
        }
      } catch {
        fputs("Bridge error: \(error)\n", stderr)
      }
      onExit?()
    }
    _task.withLock { $0 = task }
  }

  public func write(_ bytes: some Sequence<UInt8>) {
    var payload = Array(bytes)
    payload.append(0x0A)
    inputContinuation.yield(payload)
  }

  public func terminate() {
    inputContinuation.finish()
    _task.withLock { $0?.cancel() }
  }
}
