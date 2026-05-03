import Darwin.C
import struct Foundation.Data
import protocol Foundation.DataProtocol
import struct Foundation.Decimal
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import class Foundation.NSDecimalNumber
import XcodeMCPTapShared

/// Thin JSON-RPC layer over a subprocess transport.
///
/// Owns the subprocess end-to-end: construct with an executable and
/// arguments, call `start()` to kick off the supervising task and read
/// loop, then use `request`/`notify`/`forward`/`passthrough`. Call
/// `terminate()` to close stdin (well-behaved subprocesses exit) and
/// cancel the supervising task.
///
/// Reserved IDs for requests issued via `request(method:params:)` are
/// negative; clients forwarding through `forward` are expected to use
/// positive IDs.
public actor MCPConnection {
  private let exec: String
  private let args: [String]
  private let serviceName: String

  /// Writes to the subprocess's stdin.
  private let writes: AsyncStream<[UInt8]>.Continuation
  /// Reads from the subprocess's stdout (one line per element).
  private let reads: AsyncStream<[UInt8]>
  /// Reads from the subprocess's stderr (one line per element).
  private let errs: AsyncStream<[UInt8]>
  /// One-shot pid stream.
  private let pidStream: AsyncStream<pid_t>
  private var bridgeTask: Task<Void, Never>?

  private var pending: [Int: CheckedContinuation<RPCEnvelope, any Error>] = [:]
  private var nextReservedID = -1
  private let passthroughContinuation: AsyncStream<[UInt8]>.Continuation
  private var _processID: pid_t = 0

  /// Ring buffer of the most recent stderr lines emitted by the
  /// subprocess. Exposed via `recentStderr` so callers can include the
  /// real failure reason in messages they surface to their own clients.
  private var stderrBuffer: [String] = []
  private let stderrBufferLimit = 16

  public nonisolated let passthrough: AsyncStream<[UInt8]>

  public init(serviceName: String, exec: String, _ args: String...) {
    self.init(serviceName: serviceName, exec: exec, args: args)
  }

  public init(serviceName: String, exec: String, args: [String]) {
    self.serviceName = serviceName
    self.exec = exec
    self.args = args
    // Internal channels shared between the owning bridge task and this actor.
    let (writeStream, writeCont) = AsyncStream<[UInt8]>.makeStream()
    let (readStream, readCont) = AsyncStream<[UInt8]>.makeStream()
    let (errStream, errCont) = AsyncStream<[UInt8]>.makeStream()
    let (pidStream, pidCont) = AsyncStream<pid_t>.makeStream()
    self.writes = writeCont
    self.reads = readStream
    self.errs = errStream
    self.pidStream = pidStream
    (self.passthrough, self.passthroughContinuation) = AsyncStream.makeStream()

    // Capture values needed by the supervising task; the BridgeProcess
    // is created INSIDE the task closure so there is no consume capture.
    let capturedExec = exec
    let capturedArgs = args
    let capturedServiceName = serviceName
    self.bridgeTask = Task {
      let bridge = BridgeProcess(
        exec: capturedExec,
        args: capturedArgs,
        input: writeStream,
        output: readCont,
        stderr: errCont,
        pid: pidCont,
        transport: DispatchIOPipeTransport(),
        serviceName: capturedServiceName,
      )
      await bridge.run()
    }
  }

  public var processID: pid_t { _processID }

  /// Snapshot of the most recent stderr lines, joined with newlines.
  /// Safe to read at any time; empty if the subprocess has not written
  /// any stderr yet.
  public var recentStderr: String {
    stderrBuffer.joined(separator: "\n")
  }

  public func start() {
    Task { await self.readLoop() }
    Task { await self.errLoop() }
    let pids = pidStream
    Task { [weak self] in
      for await pid in pids {
        await self?.setPID(pid)
      }
    }
  }

  /// Sends a request with a reserved internal ID and awaits the matching response.
  public func request(method: String, params: JSONValue) async throws -> RPCEnvelope {
    let id = reserveID()
    let envelope = RPCEnvelope(
      id: .number(Decimal(id)),
      method: method,
      rest: [
        "jsonrpc": "2.0",
        "params": params,
      ],
    )
    let data = try JSONEncoder().encode(envelope)
    return try await withCheckedThrowingContinuation { cont in
      pending[id] = cont
      writes.yield(Array(data))
    }
  }

  /// Sends a notification (no response expected).
  public func notify(method: String, params: JSONValue? = nil) async throws {
    var rest: [String: JSONValue] = ["jsonrpc": "2.0"]
    if let params { rest["params"] = params }
    let envelope = RPCEnvelope(method: method, rest: rest)
    let data = try JSONEncoder().encode(envelope)
    writes.yield(Array(data))
  }

  /// Forwards raw bytes from a client through to the transport unchanged.
  public func forward(_ bytes: sending some DataProtocol) async throws {
    writes.yield(Array(bytes))
  }

  /// Closes stdin (well-behaved subprocesses exit) and cancels the
  /// supervising task. Safe to call more than once.
  public func terminate() {
    writes.finish()
    bridgeTask?.cancel()
  }

  // MARK: - Private

  private func setPID(_ pid: pid_t) { _processID = pid }

  private func reserveID() -> Int {
    let id = nextReservedID
    nextReservedID -= 1
    return id
  }

  private func appendStderr(_ line: String) {
    stderrBuffer.append(line)
    if stderrBuffer.count > stderrBufferLimit {
      stderrBuffer.removeFirst(stderrBuffer.count - stderrBufferLimit)
    }
  }

  private func readLoop() async {
    for await line in reads {
      if let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: Data(line)),
         case let .number(n)? = envelope.id
      {
        let id = NSDecimalNumber(decimal: n).intValue
        if id < 0, let cont = pending.removeValue(forKey: id) {
          cont.resume(returning: envelope)
          continue
        }
      }
      passthroughContinuation.yield(line)
    }
    passthroughContinuation.finish()
    for (_, cont) in pending {
      cont.resume(throwing: MCPConnectionError.transportClosed)
    }
    pending.removeAll()
  }

  private func errLoop() async {
    for await bytes in errs {
      guard let line = String(bytes: bytes, encoding: .utf8) else { continue }
      appendStderr(line)
    }
  }
}

public enum MCPConnectionError: Error, CustomStringConvertible {
  case transportClosed

  public var description: String {
    switch self {
    case .transportClosed: "MCPConnection transport closed before response arrived"
    }
  }
}
