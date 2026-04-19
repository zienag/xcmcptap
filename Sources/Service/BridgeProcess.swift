import Darwin.C
import os
import XcodeMCPTapShared

private let log = Logger(subsystem: MCPTap.serviceName, category: "bridge")

struct BridgeProcess<Transport: PipeTransport>: ~Copyable, Sendable {
  private let exec: String
  private let args: [String]
  private let input: AsyncStream<[UInt8]>
  private let output: AsyncStream<[UInt8]>.Continuation
  private let stderr: AsyncStream<[UInt8]>.Continuation
  private let pid: AsyncStream<pid_t>.Continuation
  private let transport: Transport

  init(
    exec: String,
    args: [String],
    input: AsyncStream<[UInt8]>,
    output: AsyncStream<[UInt8]>.Continuation,
    stderr: AsyncStream<[UInt8]>.Continuation,
    pid: AsyncStream<pid_t>.Continuation,
    transport: Transport,
  ) {
    self.exec = exec
    self.args = args
    self.input = input
    self.output = output
    self.stderr = stderr
    self.pid = pid
    self.transport = transport
  }

  func run() async {
    let path = exec
    let arguments = args
    let out = output
    let err = stderr
    let pidSink = pid
    let inStream = input
    let transport = transport

    defer {
      out.finish()
      err.finish()
      pidSink.finish()
    }

    let stdinPipe: AnonymousPipe
    let stdoutPipe: AnonymousPipe
    let stderrPipe: AnonymousPipe
    do {
      stdinPipe = try AnonymousPipe()
      stdoutPipe = try AnonymousPipe()
      stderrPipe = try AnonymousPipe()
    } catch {
      log.error("pipe setup failed: \(String(describing: error), privacy: .public)")
      return
    }

    _ = fcntl(stdinPipe.writeEnd, F_SETNOSIGPIPE, 1)

    let process: SpawnedProcess
    do {
      process = try SpawnedProcess.spawn(
        exec: path,
        args: arguments,
        stdin: stdinPipe.readEnd,
        stdout: stdoutPipe.writeEnd,
        stderr: stderrPipe.writeEnd,
      )
    } catch {
      log.error("spawn failed: \(String(describing: error), privacy: .public)")
      stdinPipe.closeBothEnds()
      stdoutPipe.closeBothEnds()
      stderrPipe.closeBothEnds()
      return
    }

    stdinPipe.closeReadEnd()
    stdoutPipe.closeWriteEnd()
    stderrPipe.closeWriteEnd()

    log.info("spawned pid=\(process.pid, privacy: .public) exec=\(path, privacy: .public)")
    pidSink.yield(process.pid)
    pidSink.finish()

    let (stderrLines, stderrCont) = AsyncStream<[UInt8]>.makeStream()

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await transport.readLines(
          fromFD: stdoutPipe.readEnd,
          queueLabel: "BridgeProcess.stdout",
          into: out,
        )
      }
      group.addTask {
        await transport.readLines(
          fromFD: stderrPipe.readEnd,
          queueLabel: "BridgeProcess.stderr",
          into: stderrCont,
        )
      }
      group.addTask {
        for await line in stderrLines {
          if let s = String(bytes: line, encoding: .utf8) {
            log.error("stderr: \(s, privacy: .public)")
          }
          err.yield(line)
        }
      }
      let pumpTask = Task {
        await transport.pumpMessages(inStream, toFD: stdinPipe.writeEnd)
      }
      _ = await group.next()
      pumpTask.cancel()
      await group.waitForAll()
      _ = await pumpTask.value
    }

    _ = await process.waitForExit()
  }

  deinit {
    output.finish()
    stderr.finish()
    pid.finish()
  }
}

