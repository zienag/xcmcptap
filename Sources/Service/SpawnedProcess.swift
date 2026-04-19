import Darwin.C
import Dispatch
import Synchronization

struct SpawnedProcess: Sendable {
  let pid: pid_t
  private let exit: ExitWatcher

  static func spawn(
    exec: String,
    args: [String],
    stdin: Int32,
    stdout: Int32,
    stderr: Int32,
  ) throws -> SpawnedProcess {
    var fileActions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw SpawnError.posixSpawnFailed(errno: errno)
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    for (source, target) in [(stdin, Int32(0)), (stdout, Int32(1)), (stderr, Int32(2))] {
      let rc = posix_spawn_file_actions_adddup2(&fileActions, source, target)
      guard rc == 0 else { throw SpawnError.posixSpawnFailed(errno: rc) }
    }

    var attrs: posix_spawnattr_t?
    guard posix_spawnattr_init(&attrs) == 0 else {
      throw SpawnError.posixSpawnFailed(errno: errno)
    }
    defer { posix_spawnattr_destroy(&attrs) }
    let flagsRC = posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    guard flagsRC == 0 else { throw SpawnError.posixSpawnFailed(errno: flagsRC) }

    let argv: [UnsafeMutablePointer<CChar>?] = ([exec] + args).map { strdup($0) }
    defer {
      for p in argv { free(p) }
    }
    var argvTerminated = argv + [nil]

    var pid: pid_t = 0
    let rc = exec.withCString { path in
      argvTerminated.withUnsafeMutableBufferPointer { buf in
        posix_spawn(&pid, path, &fileActions, &attrs, buf.baseAddress, environ)
      }
    }
    guard rc == 0 else { throw SpawnError.posixSpawnFailed(errno: rc) }

    let watcher = ExitWatcher(pid: pid)
    watcher.startMonitoring()
    return SpawnedProcess(pid: pid, exit: watcher)
  }

  func waitForExit() async -> Int32 {
    await withTaskCancellationHandler {
      await exit.wait()
    } onCancel: {
      terminate()
    }
  }

  func terminate() {
    kill(pid, SIGTERM)
  }
}

enum SpawnError: Error, CustomStringConvertible {
  case posixSpawnFailed(errno: Int32)

  var description: String {
    switch self {
    case let .posixSpawnFailed(errno):
      "posix_spawn failed: errno=\(errno)"
    }
  }
}

private final class ExitWatcher: Sendable {
  private struct State {
    var status: Int32?
    var waiters: [CheckedContinuation<Int32, Never>] = []
  }

  private let pid: pid_t
  private let state = Mutex(State())
  private let source: DispatchSourceProcess

  init(pid: pid_t) {
    self.pid = pid
    self.source = DispatchSource.makeProcessSource(
      identifier: pid,
      eventMask: .exit,
      queue: .global(),
    )
  }

  func startMonitoring() {
    source.setEventHandler { [self] in
      source.cancel()
      var raw: Int32 = 0
      _ = waitpid(pid, &raw, 0)
      deliver(status: raw)
    }
    source.resume()
  }

  private func deliver(status: Int32) {
    let waiters = state.withLock { inner -> [CheckedContinuation<Int32, Never>] in
      inner.status = status
      let ws = inner.waiters
      inner.waiters = []
      return ws
    }
    for cont in waiters { cont.resume(returning: status) }
  }

  func wait() async -> Int32 {
    await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
      let pending: Int32? = state.withLock { inner in
        if let status = inner.status { return status }
        inner.waiters.append(cont)
        return nil
      }
      if let pending { cont.resume(returning: pending) }
    }
  }
}
