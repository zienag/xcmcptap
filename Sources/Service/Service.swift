import Darwin
import struct Foundation.UUID
import Synchronization
import XPC
import XcodeMCPTapShared

public enum ServiceMain {
  public static func run() {
    fputs("[service] starting\n", stderr)

    let registry = ConnectionRegistry()
    let statusEndpoint = StatusEndpoint(registry: registry)

    // Start mcpbridge at service startup (before dispatchMain).
    // mcpbridge cannot be spawned from XPC accept handlers — it fails
    // with a decode error when launched in that context.
    let connection = MCPConnection(exec: "/usr/bin/xcrun", "mcpbridge")
    let router = MCPRouter(connection: connection)

    router.onToolsDiscovered = { tools in
      registry.updateTools(tools)
    }

    router.start()

    // Wait for the init handshake to complete, then snapshot the
    // subprocess PID into a box the XPC accept handler can read.
    let bridgePID = Mutex<pid_t>(0)
    Task {
      try? await Task.sleep(for: .seconds(2))
      let pid = await connection.processID
      bridgePID.withLock { $0 = pid }
      fputs("[service] bridge started, PID=\(pid)\n", stderr)
    }

    sleep(2)

    let listener = try! XPCListener(
      service: MCPTap.serviceName
    ) { request in
      fputs("[service] new XPC connection\n", stderr)
      let connectionID = UUID()

      let (decision, session) = request.accept(
        incomingMessageHandler: { (message: MCPLine) -> (any Encodable)? in
          fputs("[service] received from client: \(message.content.prefix(100))\n", stderr)
          registry.recordMessage(id: connectionID)
          router.handleClientMessage(from: connectionID, message.content)
          return nil
        },
        cancellationHandler: { _ in
          fputs("[service] connection cancelled\n", stderr)
          router.unregisterClient(id: connectionID)
          registry.unregister(id: connectionID)
        }
      )

      _ = router.registerClient(id: connectionID) { line in
        fputs("[service] sending to client: \(line.prefix(100))\n", stderr)
        try? session.send(MCPLine(line))
      }

      let snapshot = bridgePID.withLock { $0 }
      _ = registry.register(id: connectionID, bridgePID: snapshot)
      return decision
    }

    let statusListener = try! statusEndpoint.start()
    fputs("[service] listeners ready\n", stderr)

    withExtendedLifetime((listener, statusListener, router)) {
      dispatchMain()
    }
  }
}
