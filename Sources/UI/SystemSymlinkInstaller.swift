import Darwin.C
import class Foundation.Bundle
import func Foundation.NSHomeDirectory
import ServiceManagement
import XcodeMCPTapShared
import XPC

/// Errors raised by the system-symlink install flow that callers may want to
/// react to specifically (e.g. opening Login Items when approval is needed).
public enum SystemSymlinkInstallerError: Error, Equatable, Sendable {
  /// `SMAppService.daemon(...).register()` succeeded at the BTM level but the
  /// user still has to flip the switch in System Settings > Login Items before
  /// the daemon is allowed to run.
  case requiresApproval
}

/// Narrow handle to an open XPC session with the privileged helper daemon.
/// Stubbed in tests; backed by `XPCSession` in production.
public struct HelperSession: Sendable {
  public var send: @Sendable (HelperRequest) async throws -> HelperResponse
  public var close: @Sendable () -> Void

  public init(
    send: @Sendable @escaping (HelperRequest) async throws -> HelperResponse,
    close: @Sendable @escaping () -> Void,
  ) {
    self.send = send
    self.close = close
  }
}

/// Orchestrates the install/uninstall flow for `/usr/local/bin/xcmcptap`:
/// registers the privileged daemon (triggers admin prompt on first use),
/// opens an XPC session to it, sends the request, closes the session.
public struct SystemSymlinkInstaller: Sendable {
  public var registerDaemon: @Sendable () async throws -> Void
  public var openHelperSession: @Sendable () async throws -> HelperSession

  public init(
    registerDaemon: @Sendable @escaping () async throws -> Void,
    openHelperSession: @Sendable @escaping () async throws -> HelperSession,
  ) {
    self.registerDaemon = registerDaemon
    self.openHelperSession = openHelperSession
  }

  public func install(source: String) async throws -> HelperResponse {
    try await send(.installSymlink(sourcePath: source))
  }

  public func uninstall() async throws -> HelperResponse {
    try await send(.removeSymlink)
  }

  private func send(_ request: HelperRequest) async throws -> HelperResponse {
    try await registerDaemon()
    let session = try await openHelperSession()
    do {
      let response = try await session.send(request)
      session.close()
      return response
    } catch {
      session.close()
      throw error
    }
  }
}

public extension SystemSymlinkInstaller {
  /// Live wiring: registers the bundled helper daemon plist with SMAppService
  /// and opens an XPC session to the helper's Mach service.
  static let live = SystemSymlinkInstaller(
    registerDaemon: {
      let daemon = SMAppService.daemon(plistName: "\(MCPTap.helperServiceName).plist")
      do {
        try daemon.register()
      } catch {
        // On a first-time (or not-yet-approved) daemon, `register()` throws
        // `Operation not permitted` even though BTM accepted the registration.
        // Surface that as `requiresApproval` so the UI can redirect the user
        // to Login Items instead of silently failing.
        if daemon.status == .requiresApproval {
          throw SystemSymlinkInstallerError.requiresApproval
        }
        throw error
      }
    },
    openHelperSession: {
      let xpc = try XPCSession(
        machService: MCPTap.helperServiceName,
        incomingMessageHandler: { (_: HelperResponse) -> (any Encodable)? in nil },
        cancellationHandler: nil,
      )
      return HelperSession(
        send: { request in
          try xpc.sendSync(request) as HelperResponse
        },
        close: {
          xpc.cancel(reason: "helper session done")
        },
      )
    },
  )
}
