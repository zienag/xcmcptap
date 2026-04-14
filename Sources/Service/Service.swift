import Darwin
import class Foundation.FileManager
import func Foundation.NSHomeDirectory
import struct Foundation.UUID
import XcodeMCPTapShared
import XPC

public enum ServiceMain {
  /// Redirects stdout/stderr to a per-user log file. The bundled LaunchAgent
  /// plist can't express `$HOME`-relative paths, so we do the redirect here
  /// instead of via `StandardOutPath`/`StandardErrorPath`.
  private static func redirectLogsToHomeLogDir() {
    let logDir = NSHomeDirectory() + "/Library/Logs"
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    let logPath = logDir + "/\(MCPTap.serviceName).log"
    _ = logPath.withCString { freopen($0, "a", stdout) }
    _ = logPath.withCString { freopen($0, "a", stderr) }
    setbuf(stdout, nil)
    setbuf(stderr, nil)
  }

  public static func run() {
    redirectLogsToHomeLogDir()
    fputs("[service] starting\n", stderr)

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
        fputs("[service] Xcode terminated — marking bridge unavailable\n", stderr)
        Task { await router.markBridgeUnavailable(reason: "Xcode not running") }
      },
      onLaunched: {
        fputs("[service] Xcode launched — bridge will respawn on next request\n", stderr)
      },
    )

    router.start()

    let listener: XPCListener
    do {
      listener = try XPCListener(service: MCPTap.serviceName) { request in
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
          },
        )

        _ = router.registerClient(id: connectionID) { line in
          fputs("[service] sending to client: \(line.prefix(100))\n", stderr)
          try? session.send(MCPLine(line))
        }

        // Bridge PID is not meaningful across respawns; report 0.
        _ = registry.register(id: connectionID, bridgePID: 0)
        return decision
      }
    } catch {
      fputs("[service] failed to activate MCP listener: \(error)\n", stderr)
      exit(EX_CONFIG)
    }

    let statusListener: XPCListener
    do {
      statusListener = try statusEndpoint.start()
    } catch {
      fputs("[service] failed to activate status listener: \(error)\n", stderr)
      exit(EX_CONFIG)
    }
    fputs("[service] listeners ready\n", stderr)

    withExtendedLifetime((listener, statusListener, router, xcodeMonitor)) {
      dispatchMain()
    }
  }
}
