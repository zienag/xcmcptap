import Darwin.C
import Dispatch
import struct Foundation.UUID
import os
import XcodeMCPTapShared
import XPC

private let lifecycleLog = Logger(subsystem: MCPTap.serviceName, category: "service.lifecycle")
private let xpcLog = Logger(subsystem: MCPTap.serviceName, category: "service.xpc")

public enum ServiceMain {
  public static func run() {
    lifecycleLog.notice("starting")

    let registry = ConnectionRegistry()
    let statusEndpoint = StatusEndpoint(registry: registry)

    // Start mcpbridge at service startup (before dispatchMain).
    // mcpbridge cannot be spawned from XPC accept handlers — it fails
    // with a decode error when launched in that context.
    //
    // The router owns a connection FACTORY rather than a single
    // connection so that if mcpbridge dies (e.g. Xcode wasn't running
    // on first spawn, or the user quit Xcode later) the next client
    // message drives a fresh subprocess without any external restart.
    let router = MCPRouter(makeConnection: {
      MCPConnection(exec: "/usr/bin/xcrun", "mcpbridge")
    })

    router.onToolsDiscovered = { tools in
      registry.updateTools(tools)
    }
    router.onBridgeStateChanged = { status in
      registry.updateBridge(status)
    }

    // Proactively flip the bridge to .failed the moment Xcode quits, so
    // the UI doesn't keep showing a stale .ready until the next tool
    // call surfaces the failure. On launch we just log — auto-respawn
    // is driven by the next client request via the router's existing
    // recovery path.
    let xcodeMonitor = XcodeLifecycleMonitor(
      onTerminated: {
        lifecycleLog.notice("Xcode terminated — marking bridge unavailable")
        router.markBridgeUnavailable(reason: "Xcode not running")
      },
      onLaunched: {
        lifecycleLog.notice("Xcode launched — bridge will respawn on next request")
      },
    )

    router.start()

    let listener: XPCListener
    do {
      listener = try XPCListener(service: MCPTap.serviceName) { request in
        xpcLog.info("new XPC connection")
        let connectionID = UUID()

        let (decision, session) = request.accept(
          incomingMessageHandler: { (message: MCPLine) -> (any Encodable)? in
            xpcLog.debug("received from client: \(message.content.prefix(100), privacy: .private)")
            registry.recordMessage(id: connectionID)
            router.handleClientMessage(from: connectionID, message.content)
            return nil
          },
          cancellationHandler: { _ in
            xpcLog.info("connection cancelled")
            router.unregisterClient(id: connectionID)
            registry.unregister(id: connectionID)
          },
        )

        _ = router.registerClient(id: connectionID) { line in
          xpcLog.debug("sending to client: \(line.prefix(100), privacy: .private)")
          try? session.send(MCPLine(line))
        }

        // Bridge PID is not meaningful across respawns; report 0.
        _ = registry.register(id: connectionID, bridgePID: 0)
        return decision
      }
    } catch {
      lifecycleLog.fault("failed to activate MCP listener: \(String(describing: error), privacy: .public)")
      exit(EX_CONFIG)
    }

    let statusListener: XPCListener
    do {
      statusListener = try statusEndpoint.start()
    } catch {
      lifecycleLog.fault("failed to activate status listener: \(String(describing: error), privacy: .public)")
      exit(EX_CONFIG)
    }
    lifecycleLog.notice("listeners ready")

    withExtendedLifetime((listener, statusListener, router, xcodeMonitor)) {
      dispatchMain()
    }
  }
}
