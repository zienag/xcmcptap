import Darwin.C

struct AnonymousPipe {
  let readEnd: Int32
  let writeEnd: Int32

  init() throws {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else {
      throw AnonymousPipeError.creationFailed(errno: errno)
    }
    self.readEnd = fds[0]
    self.writeEnd = fds[1]
  }

  func closeReadEnd() {
    _ = close(readEnd)
  }

  func closeWriteEnd() {
    _ = close(writeEnd)
  }

  func closeBothEnds() {
    closeReadEnd()
    closeWriteEnd()
  }
}

enum AnonymousPipeError: Error, CustomStringConvertible {
  case creationFailed(errno: Int32)

  var description: String {
    switch self {
    case let .creationFailed(errno):
      "pipe(2) failed: errno=\(errno)"
    }
  }
}
