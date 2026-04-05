import SwiftUI

@main
struct XcodeMCPTapApp: App {
  @State private var viewModel = StatusViewModel()

  var body: some Scene {
    Window("Xcode MCP Tap", id: "main") {
      ContentView(viewModel: viewModel)
    }
    .defaultSize(width: 500, height: 400)
  }
}
