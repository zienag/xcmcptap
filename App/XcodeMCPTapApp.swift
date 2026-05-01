import ComposableArchitecture
import SwiftUI
import XcodeMCPTapUI

@main
struct XcodeMCPTapApp: App {
  @State private var store = Store(
    initialState: AppFeature.State(appVersion: Self.bundleShortVersion()),
  ) { AppFeature() }

  private static func bundleShortVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

  var body: some Scene {
    Window("Xcode MCP Tap", id: "main") {
      ContentView(store: store)
    }
    .windowToolbarStyle(.unifiedCompact)
    .defaultSize(width: 780, height: 460)
    .windowResizability(.contentMinSize)
  }
}
