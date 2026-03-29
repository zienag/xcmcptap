import SwiftUI

@main
struct XcodeMCPProxyApp: App {
  @State private var viewModel = StatusViewModel()

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(viewModel: viewModel)
    } label: {
      Label("XcodeMCPProxy", systemImage: viewModel.menuBarIcon)
    }
    .menuBarExtraStyle(.window)
  }
}
