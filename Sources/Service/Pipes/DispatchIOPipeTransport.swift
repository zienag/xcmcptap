import Darwin.C
import Dispatch

struct DispatchIOPipeTransport: PipeTransport {
  func readLines(
    fromFD fd: Int32,
    queueLabel: String,
    into continuation: AsyncStream<[UInt8]>.Continuation,
  ) async {
    let queue = DispatchQueue(label: queueLabel)

    await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
      var buffer: [UInt8] = []
      let channel = DispatchIO(
        type: .stream,
        fileDescriptor: fd,
        queue: queue,
        cleanupHandler: { _ in
          _ = close(fd)
        },
      )
      channel.setLimit(lowWater: 1)
      channel.read(offset: 0, length: Int.max, queue: queue) { isDone, data, _ in
        if let data, !data.isEmpty {
          data.enumerateBytes { chunk, _, _ in
            var segmentStart = 0
            for i in 0..<chunk.count where chunk[i] == 0x0A {
              if buffer.isEmpty {
                continuation.yield(Array(chunk[segmentStart..<i]))
              } else {
                buffer.append(contentsOf: chunk[segmentStart..<i])
                continuation.yield(buffer)
                buffer = []
              }
              segmentStart = i + 1
            }
            if segmentStart < chunk.count {
              buffer.append(contentsOf: chunk[segmentStart..<chunk.count])
            }
          }
        }
        if isDone {
          if !buffer.isEmpty {
            continuation.yield(buffer)
            buffer = []
          }
          continuation.finish()
          channel.close()
          resume.resume()
        }
      }
    }
  }

  func pumpMessages(
    _ stream: AsyncStream<[UInt8]>,
    toFD fd: Int32,
  ) async {
    defer { _ = close(fd) }
    for await bytes in stream {
      if Task.isCancelled { break }
      var payload = bytes
      payload.append(0x0A)
      let delivered = payload.withUnsafeBytes { raw -> Bool in
        guard var p = raw.baseAddress else { return true }
        var remaining = raw.count
        while remaining > 0 {
          let n = write(fd, p, remaining)
          if n <= 0 { return false }
          p = p.advanced(by: n)
          remaining -= n
        }
        return true
      }
      if !delivered { break }
    }
  }
}
