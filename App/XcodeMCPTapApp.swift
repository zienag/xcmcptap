import ComposableArchitecture
import SwiftUI
import XcodeMCPTapShared
import XcodeMCPTapUI

@main
struct XcodeMCPTapApp: App {
  @State private var store: StoreOf<AppFeature>

  init() {
    let identity = BuildConfig.identity
    let installer = ServiceInstaller(identity: identity)
    prepareDependencies {
      $0.serviceInstaller = .live(installer: installer)
      $0.statusClient = .live(statusServiceName: identity.statusServiceName)
    }
    store = Store(
      initialState: AppFeature.State(
        appDisplayName: identity.appDisplayName,
        appVersion: Self.bundleShortVersion(),
      ),
    ) { AppFeature() }
  }

  private static func bundleShortVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

  var body: some Scene {
    Window(BuildConfig.identity.appDisplayName, id: "main") {
      ContentView(store: store)
    }
    .windowToolbarStyle(.unifiedCompact)
    .defaultSize(width: 780, height: 460)
    .windowResizability(.contentMinSize)
  }
}
