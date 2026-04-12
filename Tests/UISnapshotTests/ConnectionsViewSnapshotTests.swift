import ComposableArchitecture
import SnapshotTesting
import SwiftUI
import Testing
import XcodeMCPTapUI

@MainActor
@Suite(.snapshots(record: .missing))
struct ConnectionsViewSnapshotTests {
  static let size = CGSize(width: 640, height: 280)

  @Test
  func active() {
    let controller = NSHostingController(
      rootView: ConnectionsView(
        store: Store(initialState: .previewRunning()) { AppFeature() }
      )
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }

  @Test
  func empty() {
    var state = AppFeature.State.previewIdle()
    state.connections = []
    let controller = NSHostingController(
      rootView: ConnectionsView(store: Store(initialState: state) { AppFeature() })
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }
}
