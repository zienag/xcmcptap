struct TimeoutError: Error, CustomStringConvertible {
  var description: String { "Timed out waiting for response" }
}

final class ResponseCollector: Sendable {
  let stream: AsyncStream<String>
  let continuation: AsyncStream<String>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func nextResponse(timeout: Duration = .seconds(15)) async throws -> String {
    try await withThrowingTaskGroup(of: String?.self) { group in
      group.addTask {
        for await line in self.stream {
          return line
        }
        return nil
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        return nil
      }
      guard let result = try await group.next(), let line = result else {
        group.cancelAll()
        throw TimeoutError()
      }
      group.cancelAll()
      return line
    }
  }

  func collect(count: Int, timeout: Duration = .seconds(15)) async throws -> [String] {
    try await withThrowingTaskGroup(of: [String].self) { group in
      group.addTask {
        var lines: [String] = []
        for await line in self.stream {
          lines.append(line)
          if lines.count >= count { break }
        }
        return lines
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        return []
      }
      guard let result = try await group.next(), !result.isEmpty else {
        group.cancelAll()
        throw TimeoutError()
      }
      group.cancelAll()
      return result
    }
  }
}
