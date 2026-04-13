import ComposableArchitecture
import SnapshotTesting
import SwiftUI
import Testing
import XcodeMCPTapUI

@MainActor
@Suite(.snapshots(record: .missing))
struct ToolsViewSnapshotTests {
  static let size = CGSize(width: 820, height: 520)

  @Test
  func populated() {
    let tools = AppFeature.State.sampleTools
    let controller = hostedInWindow(
      ToolsView(
        store: Store(
          initialState: ToolsFeature.State(
            selectedToolID: tools.first?.id,
            tools: tools
          )
        ) { ToolsFeature() }
      ),
      size: Self.size
    )
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }

  @Test
  func empty() {
    let controller = hostedInWindow(
      ToolsView(store: Store(initialState: ToolsFeature.State()) { ToolsFeature() }),
      size: Self.size
    )
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }

  @Test
  func searchMatch() {
    let controller = hostedInWindow(
      ToolsView(
        store: Store(
          initialState: ToolsFeature.State(
            searchText: "build",
            tools: AppFeature.State.sampleTools
          )
        ) { ToolsFeature() }
      ),
      size: Self.size
    )
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }

  @Test
  func searchNoMatch() {
    let controller = hostedInWindow(
      ToolsView(
        store: Store(
          initialState: ToolsFeature.State(
            searchText: "zzz",
            tools: AppFeature.State.sampleTools
          )
        ) { ToolsFeature() }
      ),
      size: Self.size
    )
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }

  @Test
  func populatedRTL() {
    let tools = AppFeature.State.sampleTools
    let controller = hostedInWindow(
      ToolsView(
        store: Store(
          initialState: ToolsFeature.State(
            selectedToolID: tools.first?.id,
            tools: tools
          )
        ) { ToolsFeature() }
      )
      .environment(\.layoutDirection, .rightToLeft),
      size: Self.size
    )
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }
}
