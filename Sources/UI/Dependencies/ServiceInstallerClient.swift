import ComposableArchitecture

@DependencyClient
public struct ServiceInstallerClient: Sendable {
  public var install: @Sendable () -> Void
  public var uninstall: @Sendable () -> Void
  public var installSystemPath: @Sendable () -> Void
  public var uninstallSystemPath: @Sendable () -> Void
  public var isInstalled: @Sendable () -> Bool = { false }
  public var requiresApproval: @Sendable () -> Bool = { false }
  public var openLoginItems: @Sendable () -> Void
  public var isOnSystemPath: @Sendable () -> Bool = { false }
  public var clientPath: @Sendable () -> String = { "" }
  public var systemPath: @Sendable () -> String = { "" }
  public var plistPath: @Sendable () -> String = { "" }
}

extension ServiceInstallerClient: DependencyKey {
  public static let liveValue = ServiceInstallerClient(
    install: { ServiceInstaller.install() },
    uninstall: { ServiceInstaller.uninstall() },
    installSystemPath: { ServiceInstaller.installSystemSymlink() },
    uninstallSystemPath: { ServiceInstaller.uninstallSystemSymlink() },
    isInstalled: { ServiceInstaller.isInstalled() },
    requiresApproval: { ServiceInstaller.requiresApproval() },
    openLoginItems: { ServiceInstaller.openLoginItems() },
    isOnSystemPath: { ServiceInstaller.isOnSystemPath() },
    clientPath: { ServiceInstaller.clientLinkPath },
    systemPath: { ServiceInstaller.systemLinkPath },
    plistPath: { ServiceInstaller.plistPath },
  )

  public static let testValue = ServiceInstallerClient()
}

public extension DependencyValues {
  var serviceInstaller: ServiceInstallerClient {
    get { self[ServiceInstallerClient.self] }
    set { self[ServiceInstallerClient.self] = newValue }
  }
}
