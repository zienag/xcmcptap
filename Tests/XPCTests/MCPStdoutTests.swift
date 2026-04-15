import Synchronization
import Testing
import XcodeMCPTapClient
import XcodeMCPTapShared

/// Pins the MCPStdout actor's guarantees: each frame lands as content
/// bytes immediately followed by a single 0x0A terminator, atomically
/// (never interleaved with another frame mid-message), and sequentially
/// `await`ed sends preserve caller order. Concurrent sends from
/// independent Tasks may land in any order — MCP correlates by `id`,
/// not arrival order — but every frame must arrive intact.
@Suite
struct MCPStdoutTests {
  @Test func sendEmitsContentFollowedByNewline() async {
    let buffer = Mutex<[UInt8]>([])
    let stdout = MCPStdout { chunk in
      buffer.withLock { $0.append(contentsOf: chunk) }
    }

    await stdout.send(MCPLine("hello"))
    await stdout.send(MCPLine("world"))

    let bytes = buffer.withLock { $0 }
    #expect(String(bytes: bytes, encoding: .utf8) == "hello\nworld\n")
  }

  @Test func awaitedSendsPreserveCallerOrder() async {
    struct Decoder: Sendable {
      var buffered: [UInt8] = []
      var lines: [String] = []
    }
    let state = Mutex(Decoder())
    let stdout = MCPStdout { chunk in
      state.withLock { s in
        s.buffered.append(contentsOf: chunk)
        while let newline = s.buffered.firstIndex(of: 0x0A) {
          let line = Array(s.buffered[..<newline])
          s.buffered.removeSubrange(...newline)
          if let text = String(bytes: line, encoding: .utf8) {
            s.lines.append(text)
          }
        }
      }
    }

    for i in 0 ..< 20 {
      await stdout.send(MCPLine("frame-\(i)"))
    }

    let collected = state.withLock { $0.lines }
    #expect(collected == (0 ..< 20).map { "frame-\($0)" })
  }

  @Test func framesStayIntactUnderConcurrentSends() async {
    struct Decoder: Sendable {
      var buffered: [UInt8] = []
      var frames: [String] = []
    }
    let state = Mutex(Decoder())
    let stdout = MCPStdout { chunk in
      state.withLock { s in
        s.buffered.append(contentsOf: chunk)
        while let newline = s.buffered.firstIndex(of: 0x0A) {
          let line = Array(s.buffered[..<newline])
          s.buffered.removeSubrange(...newline)
          if let text = String(bytes: line, encoding: .utf8) {
            s.frames.append(text)
          }
        }
      }
    }

    await withTaskGroup(of: Void.self) { group in
      for i in 0 ..< 50 {
        group.addTask { await stdout.send(MCPLine("frame-\(i)")) }
      }
    }

    let collected = state.withLock { $0.frames }
    #expect(collected.count == 50)
    #expect(Set(collected) == Set((0 ..< 50).map { "frame-\($0)" }))
  }
}
