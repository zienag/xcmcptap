import Dispatch
import XPC
import XcodeMCPTapShared

@main
struct XcodeMCPTapClient {
  static func main() {
    let stdoutQueue = DispatchQueue(label: "stdout")

    let session: XPCSession
    do {
      session = try XPCSession(
        machService: MCPTap.serviceName,
        incomingMessageHandler: { (message: MCPLine) -> (any Encodable)? in
          stdoutQueue.async {
            print(message.content)
            fflush(stdout)
          }
          return nil
        },
        cancellationHandler: { _ in
          exit(0)
        }
      )
    } catch {
      fputs("Failed to connect to XPC service: \(error)\n", stderr)
      exit(1)
    }

    DispatchQueue.global().async {
      while let line = readLine() {
        do {
          try session.send(MCPLine(line))
        } catch {
          fputs("Failed to send: \(error)\n", stderr)
          exit(1)
        }
      }
      exit(0)
    }

    dispatchMain()
  }
}
