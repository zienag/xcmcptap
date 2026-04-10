import protocol Foundation.DataProtocol
import Darwin.C
import Subprocess
import Synchronization
import System

public final class BridgeProcess: Sendable {
  private let executablePath: String
  private let executableArgs: [String]

  public let messages: AsyncStream<[UInt8]>
  private let messagesContinuation: AsyncStream<[UInt8]>.Continuation

  private let writerLatch = Mutex(WriterLatch())
  private let _execution = Mutex<Execution?>(nil)
  private let _task = Mutex<Task<Void, Never>?>(nil)

  private struct WriterLatch: Sendable {
    var writer: StandardInputWriter?
    var waiters: [CheckedContinuation<StandardInputWriter, any Error>] = []
  }

  public var processID: pid_t {
    _execution.withLock { $0?.processIdentifier.value ?? 0 }
  }

  public init(executable: String = "/usr/bin/xcrun", arguments: [String] = ["mcpbridge"]) {
    self.executablePath = executable
    self.executableArgs = arguments
    (self.messages, self.messagesContinuation) = AsyncStream.makeStream()
  }

  public func start() {
    let messagesCont = self.messagesContinuation

    let task = Task.detached { [self] in
      do {
        _ = try await run(
          .path(FilePath(self.executablePath)),
          arguments: Arguments(self.executableArgs),
          error: .discarded,
          preferredBufferSize: 1
        ) { execution, inputWriter, outputSequence in
          self._execution.withLock { $0 = execution }
          self.signalWriter(inputWriter)

          var current: [UInt8] = []
          for try await buffer in outputSequence {
            buffer.withUnsafeBytes { raw in
              for byte in raw.bindMemory(to: UInt8.self) {
                if byte == 0x0A {
                  messagesCont.yield(current)
                  current = []
                } else {
                  current.append(byte)
                }
              }
            }
          }
          if !current.isEmpty {
            messagesCont.yield(current)
          }
        }
      } catch {
        fputs("Bridge error: \(error)\n", stderr)
        self.failWaiters(with: error)
      }
      messagesCont.finish()
    }
    _task.withLock { $0 = task }
  }

  public func write(_ bytes: some DataProtocol) async throws {
    let writer = try await awaitWriter()
    // Must be a single write: the actor serializes individual writes, but
    // splitting data and newline into two writes allows other concurrent
    // writers to interleave bytes between the payload and its terminator.
    var payload = Array(bytes)
    payload.append(0x0A)
    _ = try await writer.write(payload)
  }

  public func terminate() {
    if let execution = _execution.withLock({ $0 }) {
      try? execution.send(signal: .terminate)
    }
    _task.withLock { $0?.cancel() }
  }

  // MARK: - Private

  private func awaitWriter() async throws -> StandardInputWriter {
    try await withCheckedThrowingContinuation { cont in
      let resolved: StandardInputWriter? = writerLatch.withLock { latch in
        if let w = latch.writer {
          return w
        }
        latch.waiters.append(cont)
        return nil
      }
      if let resolved {
        cont.resume(returning: resolved)
      }
    }
  }

  private func signalWriter(_ writer: StandardInputWriter) {
    let waiters = writerLatch.withLock { latch -> [CheckedContinuation<StandardInputWriter, any Error>] in
      latch.writer = writer
      let w = latch.waiters
      latch.waiters = []
      return w
    }
    for waiter in waiters {
      waiter.resume(returning: writer)
    }
  }

  private func failWaiters(with error: any Error) {
    let waiters = writerLatch.withLock { latch -> [CheckedContinuation<StandardInputWriter, any Error>] in
      let w = latch.waiters
      latch.waiters = []
      return w
    }
    for waiter in waiters {
      waiter.resume(throwing: error)
    }
  }
}
