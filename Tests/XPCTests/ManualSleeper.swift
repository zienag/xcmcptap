import Synchronization

/// Virtual clock for deterministic timing tests. Tasks calling `sleep(for:)`
/// suspend until `advance(by:)` moves elapsed past their deadline.
/// `waitForPendingSleepers(count:)` blocks the test until at least N
/// tasks are parked, so `advance` lands only after the production code
/// has actually reached its sleep point.
///
/// Resumption happens outside the state mutex — a resumed task may
/// immediately re-park on the sleeper, and we don't want that
/// re-entrancy to deadlock on the same lock.
final class ManualSleeper: Sendable {
  private struct Pending {
    var deadline: Duration
    var continuation: CheckedContinuation<Void, Never>
  }

  private struct Watcher {
    var target: Int
    var continuation: CheckedContinuation<Void, Never>
  }

  private struct State {
    var elapsed: Duration = .zero
    var pending: [Pending] = []
    var watchers: [Watcher] = []
  }

  private let state = Mutex(State())

  init() {}

  /// Park the caller until `advance(by:)` moves elapsed past `duration`.
  /// A `.zero` (or negative) duration resumes synchronously.
  func sleep(for duration: Duration) async {
    await withCheckedContinuation { continuation in
      let resumeNow = state.withLock { s -> Bool in
        let deadline = s.elapsed + duration
        if deadline <= s.elapsed {
          return true
        }
        s.pending.append(Pending(deadline: deadline, continuation: continuation))
        return false
      }
      if resumeNow {
        continuation.resume()
      } else {
        // Outside the lock, notify any watchers whose threshold the new
        // pending entry just crossed.
        notifyWatchers()
      }
    }
  }

  /// Move virtual time forward. Resumes every pending sleeper whose
  /// deadline is now in the past.
  func advance(by duration: Duration) {
    let resumed = state.withLock { s -> [CheckedContinuation<Void, Never>] in
      s.elapsed += duration
      let ready = s.pending.filter { $0.deadline <= s.elapsed }
      s.pending.removeAll { $0.deadline <= s.elapsed }
      return ready.map(\.continuation)
    }
    for continuation in resumed {
      continuation.resume()
    }
  }

  /// Park the caller until at least `count` tasks are parked on the
  /// sleeper. Lets tests synchronize with production code that has
  /// reached its next sleep point before advancing.
  func waitForPendingSleepers(count: Int) async {
    await withCheckedContinuation { continuation in
      let resumeNow = state.withLock { s -> Bool in
        if s.pending.count >= count {
          return true
        }
        s.watchers.append(Watcher(target: count, continuation: continuation))
        return false
      }
      if resumeNow {
        continuation.resume()
      }
    }
  }

  private func notifyWatchers() {
    let satisfied = state.withLock { s -> [CheckedContinuation<Void, Never>] in
      let ready = s.watchers.filter { $0.target <= s.pending.count }
      s.watchers.removeAll { $0.target <= s.pending.count }
      return ready.map(\.continuation)
    }
    for continuation in satisfied {
      continuation.resume()
    }
  }
}
