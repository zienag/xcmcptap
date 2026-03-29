import struct Foundation.UUID
import XPC
import XcodeMCPTapShared

@main
struct XcodeMCPTapService {
  static func main() {
    fputs("[service] starting\n", stderr)

    let registry = ConnectionRegistry()
    let statusEndpoint = StatusEndpoint(registry: registry)

    let listener = try! XPCListener(
      service: MCPTap.serviceName
    ) { request in
      fputs("[service] new XPC connection\n", stderr)
      let connectionID = UUID()
      let bridge = BridgeProcess()
      let router = MCPRouter(bridge: bridge)

      let (decision, session) = request.accept(
        incomingMessageHandler: { (message: MCPLine) -> (any Encodable)? in
          fputs("[service] received from client: \(message.content.prefix(100))\n", stderr)
          registry.recordMessage(id: connectionID)
          router.handleClientMessage(message.content)
          return nil
        },
        cancellationHandler: { _ in
          fputs("[service] connection cancelled\n", stderr)
          bridge.terminate()
          registry.unregister(id: connectionID)
        }
      )

      router.sendToClient = { line in
        fputs("[service] sending to client: \(line.prefix(100))\n", stderr)
        try? session.send(MCPLine(line))
      }

      bridge.onExit = {
        fputs("[service] bridge process exited\n", stderr)
        session.cancel(reason: "bridge process exited")
        registry.unregister(id: connectionID)
      }

      router.start()
      _ = registry.register(id: connectionID, bridgePID: bridge.processID)
      fputs("[service] bridge started, PID=\(bridge.processID)\n", stderr)

      return decision
    }

    let statusListener = try! statusEndpoint.start()
    fputs("[service] listeners ready\n", stderr)

    withExtendedLifetime((listener, statusListener)) {
      dispatchMain()
    }
  }
}
