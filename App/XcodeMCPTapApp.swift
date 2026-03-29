import SwiftUI

@main
struct XcodeMCPTapApp: App {
  @State private var viewModel = StatusViewModel()

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(viewModel: viewModel)
    } label: {
      Label("Xcode MCP Tap", systemImage: viewModel.menuBarIcon)
    }
    .menuBarExtraStyle(.window)
  }
}
