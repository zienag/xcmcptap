import Darwin.C
import class Foundation.ProcessInfo
import XcodeMCPTapShared
import XPC

public enum HelperMain {
  public static func run() {
    let env = ProcessInfo.processInfo.environment
    let machService = env["HELPER_MACH_SERVICE"] ?? MCPTap.helperServiceName
    let destination = env["HELPER_DESTINATION"] ?? "/usr/local/bin/xcmcptap"

    let allowAnyPeer = env["HELPER_ALLOW_ANY_PEER"] == "1"
    fputs(
      "[helper] listening on \(machService), destination=\(destination), allowAnyPeer=\(allowAnyPeer)\n",
      stderr,
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
      fputs("[helper] failed to start listener: \(error)\n", stderr)
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
