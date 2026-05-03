import Darwin.C
import Dispatch
import struct Foundation.UUID
import os
import XcodeMCPTapShared
import XPC

public enum ServiceMain {
  public static func run(identity: Identity) {
    let lifecycleLog = Logger(subsystem: identity.serviceName, category: "service.lifecycle")
    let xpcLog = Logger(subsystem: identity.serviceName, category: "service.xpc")

    lifecycleLog.notice("starting")

    let registry = ConnectionRegistry()
    let statusEndpoint = StatusEndpoint(
      registry: registry,
      serviceName: identity.serviceName,
      statusServiceName: identity.statusServiceName,
    )

    // Start mcpbridge at service startup (before dispatchMain).
    // mcpbridge cannot be spawned from XPC accept handlers — it fails
    // with a decode error when launched in that context.
    //
    // The router owns a connection FACTORY rather than a single
    // connection so that if mcpbridge dies (e.g. Xcode wasn't running
    // on first spawn, or the user quit Xcode later) the next client
    // message drives a fresh subprocess without any external restart.
    let router = MCPRouter(
      serviceName: identity.serviceName,
      clientName: identity.appDisplayName,
      makeConnection: {
        MCPConnection(serviceName: identity.serviceName, exec: "/usr/bin/xcrun", "mcpbridge")
      },
    )

    router.onToolsDiscovered = { tools in
      registry.updateTools(tools)
    }
    router.onBridgeStateChanged = { status in
      registry.updateBridge(status)
    }

    // Proactively flip the bridge to .failed the moment Xcode quits, so
    // the UI doesn't keep showing a stale .ready until the next tool
    // call surfaces the failure. Recovery in the new fallback model is
    // driven by the agent calling `xcmcptap_reload`; the launch hook
    // just logs so the operator can correlate Xcode startup with a
    // subsequent reload attempt.
    let xcodeMonitor = XcodeLifecycleMonitor(
      onTerminated: {
        lifecycleLog.notice("Xcode terminated — marking bridge unavailable")
        router.markBridgeUnavailable(reason: "Xcode not running")
      },
      onLaunched: {
        lifecycleLog.notice("Xcode launched — call xcmcptap_reload to bring bridge back")
      },
    )

    router.start()

    let listener: XPCListener
    do {
      listener = try XPCListener(service: identity.serviceName) { request in
        xpcLog.info("new XPC connection")
        let connectionID = UUID()

        let (decision, session) = request.accept(
          incomingMessageHandler: { (message: MCPLine) -> (any Encodable)? in
            xpcLog.debug("received from client: \(message.content.prefix(100), privacy: .private)")
            Self.handleIncomingMessage(
              message,
              from: connectionID,
              registry: registry,
              router: router,
            )
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

        // Placeholder clientPID: the XPC `IncomingSessionRequest` does not
        // expose the peer's PID, so we register the row here and wait for
        // the client to self-report its PID in its first `MCPLine`.
        _ = registry.register(id: connectionID, clientPID: 0)
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

  /// Processes one client→service `MCPLine`: records the activity, lifts
  /// the client's self-reported PID into the registry (if present), and
  /// forwards the wire payload to the router. Exposed so tests can drive
  /// the seam without standing up an XPC listener.
  public static func handleIncomingMessage(
    _ message: MCPLine,
    from connectionID: UUID,
    registry: ConnectionRegistry,
    router: MCPRouter,
  ) {
    registry.recordMessage(id: connectionID)
    if let pid = message.clientPID, pid != 0 {
      registry.updateClientPID(id: connectionID, pid: pid)
    }
    router.handleClientMessage(from: connectionID, message.content)
  }
}
