import ComposableArchitecture
import SnapshotTesting
import SwiftUI
import Testing
import XcodeMCPTapUI

@MainActor
@Suite
struct ToolsViewSnapshotTests {
  static let size = CGSize(width: 820, height: 520)

  @Test
  func populated() {
    let tools = AppFeature.State.sampleTools
    let controller = NSHostingController(
      rootView: ToolsView(
        store: Store(
          initialState: ToolsFeature.State(
            selectedToolID: tools.first?.id,
            tools: tools,
          ),
        ) { ToolsFeature() },
      ),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }

  @Test
  func empty() {
    let controller = NSHostingController(
      rootView: ToolsView(store: Store(initialState: ToolsFeature.State()) { ToolsFeature() }),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }

  @Test
  func searchMatch() {
    let controller = NSHostingController(
      rootView: ToolsView(
        store: Store(
          initialState: ToolsFeature.State(
            searchText: "build",
            tools: AppFeature.State.sampleTools,
          ),
        ) { ToolsFeature() },
      ),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }

  @Test
  func searchNoMatch() {
    let controller = NSHostingController(
      rootView: ToolsView(
        store: Store(
          initialState: ToolsFeature.State(
            searchText: "zzz",
            tools: AppFeature.State.sampleTools,
          ),
        ) { ToolsFeature() },
      ),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }

  @Test
  func populatedRTL() {
    let tools = AppFeature.State.sampleTools
    let controller = NSHostingController(
      rootView: ToolsView(
        store: Store(
          initialState: ToolsFeature.State(
            selectedToolID: tools.first?.id,
            tools: tools,
          ),
        ) { ToolsFeature() },
      )
      .environment(\.layoutDirection, .rightToLeft),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }
}
