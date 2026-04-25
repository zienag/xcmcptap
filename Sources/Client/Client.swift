import Darwin.C
import Dispatch
import os
import XcodeMCPTapShared
import XPC

private let log = Logger(subsystem: MCPTap.serviceName, category: "client")

public enum ClientMain {
  public static func run() {
    let stdout = MCPStdout()

    let session: XPCSession
    do {
      session = try XPCSession(
        machService: MCPTap.serviceName,
        incomingMessageHandler: { (message: MCPLine) -> (any Encodable)? in
          Task { await stdout.send(message) }
          return nil
        },
        cancellationHandler: { _ in
          exit(0)
        },
      )
    } catch {
      // Agents capture the client's stderr; keep a one-liner there so the
      // user sees the error inline in their agent's log. OSLog is not
      // inherited across processes, so we emit there too.
      log.error("failed to connect to XPC service: \(String(describing: error), privacy: .public)")
      fputs("Failed to connect to XPC service: \(error)\n", stderr)
      exit(1)
    }

    let clientPID = getpid()

    DispatchQueue.global().async {
      while let line = readLine() {
        do {
          try session.send(MCPLine(line, clientPID: clientPID))
        } catch {
          log.error("failed to send: \(String(describing: error), privacy: .public)")
          fputs("Failed to send: \(error)\n", stderr)
          exit(1)
        }
      }
      exit(0)
    }

    dispatchMain()
  }
}
