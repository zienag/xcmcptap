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

public extension ServiceInstallerClient {
  /// Wires a `ServiceInstaller` (bound to the runtime build identity)
  /// behind the dependency-injected protocol the UI talks to. The @main
  /// wrapper calls `prepareDependencies { $0.serviceInstaller = .live(installer:) }`
  /// at app startup with the build's identity.
  static func live(installer: ServiceInstaller) -> ServiceInstallerClient {
    ServiceInstallerClient(
      install: { installer.install() },
      uninstall: { installer.uninstall() },
      installSystemPath: { installer.installSystemSymlink() },
      uninstallSystemPath: { installer.uninstallSystemSymlink() },
      isInstalled: { installer.isInstalled() },
      requiresApproval: { installer.requiresApproval() },
      openLoginItems: { installer.openLoginItems() },
      isOnSystemPath: { installer.isOnSystemPath() },
      clientPath: { installer.bundledClientPath },
      systemPath: { installer.systemLinkPath },
      plistPath: { installer.plistPath },
    )
  }
}

extension ServiceInstallerClient: DependencyKey {
  /// The unconfigured liveValue — every operation is a no-op. Production
  /// callers MUST replace it via `prepareDependencies { $0.serviceInstaller = .live(installer:) }`
  /// before any UI reads the dependency.
  public static let liveValue = ServiceInstallerClient()
  public static let testValue = ServiceInstallerClient()
}

public extension DependencyValues {
  var serviceInstaller: ServiceInstallerClient {
    get { self[ServiceInstallerClient.self] }
    set { self[ServiceInstallerClient.self] = newValue }
  }
}
