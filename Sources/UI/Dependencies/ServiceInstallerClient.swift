import ComposableArchitecture
import class Foundation.FileManager

@DependencyClient
public struct ServiceInstallerClient: Sendable {
  public var install: @Sendable () -> Void
  public var uninstall: @Sendable () -> Void
  public var isInstalled: @Sendable () -> Bool = { false }
  public var clientPath: @Sendable () -> String = { "" }
  public var plistPath: @Sendable () -> String = { "" }
  public var logPath: @Sendable () -> String = { "" }
}

extension ServiceInstallerClient: DependencyKey {
  public static let liveValue = ServiceInstallerClient(
    install: { ServiceInstaller.install() },
    uninstall: { ServiceInstaller.uninstall() },
    isInstalled: { FileManager.default.fileExists(atPath: ServiceInstaller.plistPath) },
    clientPath: { ServiceInstaller.clientLinkPath },
    plistPath: { ServiceInstaller.plistPath },
    logPath: { ServiceInstaller.logPath }
  )

  public static let testValue = ServiceInstallerClient()
}

extension DependencyValues {
  public var serviceInstaller: ServiceInstallerClient {
    get { self[ServiceInstallerClient.self] }
    set { self[ServiceInstallerClient.self] = newValue }
  }
}
