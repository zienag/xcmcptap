/// Drives line-oriented async I/O over anonymous pipes created with
/// `pipe(2)`. Swap the concrete conformer to retarget the subprocess
/// transport layer (e.g. raw blocking reads on a dedicated thread,
/// `kqueue`, an IOSurface, etc.) without touching `BridgeProcess`.
protocol PipeTransport: Sendable {
  /// Takes ownership of `fd`, reads until EOF, yields each newline-
  /// delimited line (stripped of `\n`) into `continuation`, finishes
  /// the continuation, and closes `fd`.
  func readLines(
    fromFD fd: Int32,
    queueLabel: String,
    into continuation: AsyncStream<[UInt8]>.Continuation,
  ) async

  /// Takes ownership of `fd`. Writes each element of `stream` as a
  /// newline-framed message. Returns when the stream finishes, the
  /// task is cancelled, or the peer closes the pipe. Closes `fd`.
  func pumpMessages(
    _ stream: AsyncStream<[UInt8]>,
    toFD fd: Int32,
  ) async
}
