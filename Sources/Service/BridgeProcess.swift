import Darwin.C
import protocol Foundation.DataProtocol
import os
import Subprocess
import System
import XcodeMCPTapShared

private let log = Logger(subsystem: MCPTap.serviceName, category: "bridge")

/// Single-ownership, move-only subprocess transport. Communicates with
/// the outside exclusively through externally-owned value-type channels
/// — no shared mutable state, no mutexes, no reference-typed backing.
///
/// Lifecycle: construct with a command + channels, then call `run()`
/// from a single owning task. That task drives the subprocess to
/// completion. Termination happens when:
///   - stdout EOF is observed (subprocess exited); the other drain/pump
///     tasks are then cancelled so the supervising task unwinds cleanly
///     even if the caller never closes the input stream.
///   - the task is cancelled (swift-subprocess propagates cancellation).
///   - the `input` stream finishes (stdin closes → well-behaved
///     subprocesses exit).
///
/// Stderr lines are logged through `os.Logger` AND yielded to the
/// `stderr` continuation so callers can surface the subprocess's own
/// error output to their clients (e.g., back through MCP as a
/// JSON-RPC error message reason).
///
/// Internal to the service module — only `MCPConnection` constructs one.
struct BridgeProcess: ~Copyable, Sendable {
  private let exec: String
  private let args: [String]
  /// Bytes to send into the subprocess's stdin.
  private let input: AsyncStream<[UInt8]>
  /// Sink that receives bytes read from the subprocess's stdout.
  private let output: AsyncStream<[UInt8]>.Continuation
  /// Sink that receives each stderr line from the subprocess.
  private let stderr: AsyncStream<[UInt8]>.Continuation
  /// One-shot sink that receives the pid once the subprocess spawns.
  private let pid: AsyncStream<pid_t>.Continuation

  init(
    exec: String,
    args: [String],
    input: AsyncStream<[UInt8]>,
    output: AsyncStream<[UInt8]>.Continuation,
    stderr: AsyncStream<[UInt8]>.Continuation,
    pid: AsyncStream<pid_t>.Continuation,
  ) {
    self.exec = exec
    self.args = args
    self.input = input
    self.output = output
    self.stderr = stderr
    self.pid = pid
  }

  /// Spawns the subprocess and drives it to completion.
  func run() async {
    let path = exec
    let arguments = args
    let out = output
    let err = stderr
    let pidSink = pid
    let inStream = input

    defer {
      out.finish()
      err.finish()
      pidSink.finish()
    }

    do {
      _ = try await Subprocess.run(
        .path(FilePath(path)),
        arguments: Arguments(arguments),
        preferredBufferSize: 1,
      ) { execution, inputWriter, outputSequence, errorSequence in
        log.info("spawned pid=\(execution.processIdentifier.value, privacy: .public) exec=\(path, privacy: .public)")
        pidSink.yield(execution.processIdentifier.value)
        pidSink.finish()

        // Drain stdout / stderr in parallel. Whichever finishes first
        // means the subprocess exited (EOF on a pipe); at that point we
        // cancel the input pump so the owning task can unwind even if
        // the client never closed stdin.
        await withTaskGroup(of: Void.self) { group in
          group.addTask { await Self.drainLines(outputSequence, into: out) }
          group.addTask { await Self.drainStderr(errorSequence, into: err) }
          let pumpTask = Task { await Self.pumpInput(inStream, to: inputWriter) }
          _ = await group.next() // any drainer finishing = subprocess gone
          pumpTask.cancel()
          await group.waitForAll()
          _ = await pumpTask.value
        }
      }
    } catch {
      log.error("subprocess failed: \(String(describing: error), privacy: .public)")
    }
  }

  deinit {
    // If the value is dropped without being consumed by `run()`, make
    // sure nobody blocks on the channels forever.
    output.finish()
    stderr.finish()
    pid.finish()
  }

  // MARK: - Private

  /// Reads newline-framed bytes from the subprocess's stdout and yields
  /// each complete line to the output continuation.
  private static func drainLines(
    _ sequence: some AsyncSequence<AsyncBufferSequence.Buffer, any Error>,
    into continuation: AsyncStream<[UInt8]>.Continuation,
  ) async {
    var current: [UInt8] = []
    do {
      for try await buffer in sequence {
        buffer.withUnsafeBytes { raw in
          for byte in raw.bindMemory(to: UInt8.self) {
            if byte == 0x0A {
              continuation.yield(current)
              current = []
            } else {
              current.append(byte)
            }
          }
        }
      }
    } catch {
      log.error("stdout read error: \(String(describing: error), privacy: .public)")
    }
    if !current.isEmpty {
      continuation.yield(current)
    }
  }

  /// Reads bytes from the input stream and writes them (newline-framed)
  /// to the subprocess's stdin. Closes stdin when the stream finishes
  /// or the owning task is cancelled.
  private static func pumpInput(
    _ stream: AsyncStream<[UInt8]>,
    to writer: StandardInputWriter,
  ) async {
    for await bytes in stream {
      if Task.isCancelled { break }
      var payload = bytes
      payload.append(0x0A)
      _ = try? await writer.write(payload)
    }
    _ = try? await writer.finish()
  }

  /// Reads the subprocess's stderr line-by-line, logs each line, and
  /// forwards it to the `stderr` continuation so the caller can surface
  /// failure reasons to its own clients.
  private static func drainStderr(
    _ sequence: some AsyncSequence<AsyncBufferSequence.Buffer, any Error>,
    into continuation: AsyncStream<[UInt8]>.Continuation,
  ) async {
    var current: [UInt8] = []
    func flush() {
      guard !current.isEmpty else { return }
      if let line = String(bytes: current, encoding: .utf8) {
        log.error("stderr: \(line, privacy: .public)")
      }
      continuation.yield(current)
      current = []
    }
    do {
      for try await buffer in sequence {
        buffer.withUnsafeBytes { raw in
          for byte in raw.bindMemory(to: UInt8.self) {
            if byte == 0x0A {
              flush()
            } else {
              current.append(byte)
            }
          }
        }
      }
    } catch {
      log.error("stderr read error: \(String(describing: error), privacy: .public)")
    }
    flush()
  }
}
