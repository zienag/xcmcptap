import Darwin.C
import Dispatch
import class Foundation.ProcessInfo
import os
import XcodeMCPTapShared
import XPC

private let log = Logger(subsystem: MCPTap.helperServiceName, category: "xpc")

public enum HelperMain {
  public static func run() {
    let env = ProcessInfo.processInfo.environment
    let machService = env["HELPER_MACH_SERVICE"] ?? MCPTap.helperServiceName
    let destination = env["HELPER_DESTINATION"] ?? "/usr/local/bin/xcmcptap"

    let allowAnyPeer = env["HELPER_ALLOW_ANY_PEER"] == "1"
    log.notice(
      "listening on \(machService, privacy: .public), destination=\(destination, privacy: .public), allowAnyPeer=\(allowAnyPeer, privacy: .public)",
    )

    let handler = HelperHandler(destination: destination)

    do {
      let listener: XPCListener = if allowAnyPeer {
        try XPCListener(service: machService) { request in
          Self.accept(request, handler: handler)
        }
      } else {
        try XPCListener(
          service: machService,
          requirement: .isFromSameTeam(andMatchesSigningIdentifier: MCPTap.serviceName),
        ) { request in
          Self.accept(request, handler: handler)
        }
      }

      withExtendedLifetime(listener) {
        dispatchMain()
      }
    } catch {
      log.fault("failed to start listener: \(String(describing: error), privacy: .public)")
      exit(1)
    }
  }

  private static func accept(
    _ request: XPCListener.IncomingSessionRequest,
    handler: HelperHandler,
  ) -> XPCListener.IncomingSessionRequest.Decision {
    let (decision, _) = request.accept(
      incomingMessageHandler: { (req: HelperRequest) -> HelperResponse in
        handler.handle(req)
      },
      cancellationHandler: nil,
    )
    return decision
  }
}
