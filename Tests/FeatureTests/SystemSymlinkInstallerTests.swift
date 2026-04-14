import ComposableArchitecture
import Testing
import XcodeMCPTapShared
import XcodeMCPTapUI

struct SystemSymlinkInstallerTests {
  @Test
  func installCallsRegisterThenSendsInstallRequest() async throws {
    let events = LockIsolated<[String]>([])

    let installer = SystemSymlinkInstaller(
      registerDaemon: {
        events.withValue { $0.append("register") }
      },
      openHelperSession: {
        events.withValue { $0.append("open") }
        return HelperSession(
          send: { request in
            events.withValue { $0.append("send:\(request)") }
            return .success
          },
          close: {
            events.withValue { $0.append("close") }
          }
        )
      }
    )

    let response = try await installer.install(source: "/some/xcmcptap")

    #expect(response == .success)
    #expect(
      events.value == [
        "register",
        "open",
        #"send:installSymlink(sourcePath: "/some/xcmcptap")"#,
        "close",
      ]
    )
  }

  @Test
  func uninstallSendsRemoveRequest() async throws {
    let sent = LockIsolated<[HelperRequest]>([])

    let installer = SystemSymlinkInstaller(
      registerDaemon: {},
      openHelperSession: {
        HelperSession(
          send: { request in
            sent.withValue { $0.append(request) }
            return .success
          },
          close: {}
        )
      }
    )

    let response = try await installer.uninstall()

    #expect(response == .success)
    #expect(sent.value == [.removeSymlink])
  }

  @Test
  func registerDaemonErrorPropagates() async {
    struct BootError: Error, Equatable {}

    let installer = SystemSymlinkInstaller(
      registerDaemon: { throw BootError() },
      openHelperSession: {
        Issue.record("openHelperSession must not be called when register fails")
        return HelperSession(send: { _ in .success }, close: {})
      }
    )

    do {
      _ = try await installer.install(source: "/bin")
      Issue.record("expected throw")
    } catch is BootError {
      // expected
    } catch {
      Issue.record("wrong error: \(error)")
    }
  }

  @Test
  func openSessionErrorPropagates() async {
    struct OpenError: Error {}

    let installer = SystemSymlinkInstaller(
      registerDaemon: {},
      openHelperSession: { throw OpenError() }
    )

    await #expect(throws: OpenError.self) {
      _ = try await installer.install(source: "/bin")
    }
  }

  @Test
  func helperFailureResponseReturnedAsIs() async throws {
    let installer = SystemSymlinkInstaller(
      registerDaemon: {},
      openHelperSession: {
        HelperSession(
          send: { _ in .failure(reason: "denied") },
          close: {}
        )
      }
    )

    let response = try await installer.install(source: "/bin")
    #expect(response == .failure(reason: "denied"))
  }

  @Test
  func requiresApprovalErrorPropagates() async {
    let opened = LockIsolated(false)

    let installer = SystemSymlinkInstaller(
      registerDaemon: { throw SystemSymlinkInstallerError.requiresApproval },
      openHelperSession: {
        opened.setValue(true)
        return HelperSession(send: { _ in .success }, close: {})
      }
    )

    await #expect(throws: SystemSymlinkInstallerError.requiresApproval) {
      _ = try await installer.install(source: "/bin")
    }
    #expect(opened.value == false, "openHelperSession must not run when approval is required")
  }

  @Test
  func sessionIsClosedEvenWhenSendThrows() async {
    struct SendError: Error {}
    let closed = LockIsolated(false)

    let installer = SystemSymlinkInstaller(
      registerDaemon: {},
      openHelperSession: {
        HelperSession(
          send: { _ in throw SendError() },
          close: { closed.setValue(true) }
        )
      }
    )

    _ = try? await installer.install(source: "/bin")
    #expect(closed.value == true)
  }
}
