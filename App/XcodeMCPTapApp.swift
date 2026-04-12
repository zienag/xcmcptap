import SwiftUI
import XcodeMCPTapUI

@main
struct XcodeMCPTapApp: App {
  @State private var viewModel = StatusViewModel()

  var body: some Scene {
    Window("Xcode MCP Tap", id: "main") {
      ContentView(viewModel: viewModel)
    }
    .windowToolbarStyle(.unifiedCompact)
    .defaultSize(width: 780, height: 460)
    .windowResizability(.contentMinSize)
  }
}
