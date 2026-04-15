import struct Foundation.Data
import class Foundation.FileHandle
import XcodeMCPTapShared

/// Sole legal writer on the client's stdout channel. The client speaks
/// the MCP wire protocol to its host agent over stdio — any stray
/// write (a stray `print`, a debug dump) would corrupt the frame
/// stream and desync the agent. Actor isolation guarantees each frame's
/// content + newline are emitted atomically (never interleaved with
/// another frame mid-message). Ordering across concurrent callers is
/// undefined, but MCP correlates responses by `id`, not order, so this
/// is protocol-safe.
public actor MCPStdout {
  public typealias Sink = @Sendable ([UInt8]) -> Void

  private let sink: Sink

  public init(sink: @escaping Sink = { bytes in
    FileHandle.standardOutput.write(Data(bytes))
  }) {
    self.sink = sink
  }

  public func send(_ frame: MCPLine) {
    sink(Array(frame.content.utf8))
    sink([0x0A])
  }
}
