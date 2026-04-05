import Darwin
import struct Foundation.UUID
import XPC
import XcodeMCPTapServiceCore
import XcodeMCPTapShared

@main
struct XcodeMCPTapService {
  static func main() {
    fputs("[service] starting\n", stderr)

    let registry = ConnectionRegistry()
    let statusEndpoint = StatusEndpoint(registry: registry)

    // Start mcpbridge at service startup (before dispatchMain).
    // mcpbridge cannot be spawned from XPC accept handlers — it fails
    // with a decode error when launched in that context.
    let bridge = BridgeProcess()
    let router = MCPRouter(bridge: bridge)

    router.onToolsDiscovered = { tools in
      registry.updateTools(tools)
    }

    router.start()
    fputs("[service] bridge started, PID=\(bridge.processID)\n", stderr)

    // Wait for the init handshake to complete before accepting connections
    sleep(2)

    bridge.onExit = {
      fputs("[service] bridge process exited\n", stderr)
    }

    let listener = try! XPCListener(
      service: MCPTap.serviceName
    ) { request in
      fputs("[service] new XPC connection\n", stderr)
      let connectionID = UUID()

      let (decision, session) = request.accept(
        incomingMessageHandler: { (message: MCPLine) -> (any Encodable)? in
          fputs("[service] received from client: \(message.content.prefix(100))\n", stderr)
          registry.recordMessage(id: connectionID)
          router.handleClientMessage(message.content)
          return nil
        },
        cancellationHandler: { _ in
          fputs("[service] connection cancelled\n", stderr)
          registry.unregister(id: connectionID)
        }
      )

      router.sendToClient = { line in
        fputs("[service] sending to client: \(line.prefix(100))\n", stderr)
        try? session.send(MCPLine(line))
      }

      _ = registry.register(id: connectionID, bridgePID: bridge.processID)
      return decision
    }

    let statusListener = try! statusEndpoint.start()
    fputs("[service] listeners ready\n", stderr)

    withExtendedLifetime((listener, statusListener, bridge, router)) {
      dispatchMain()
    }
  }
}
