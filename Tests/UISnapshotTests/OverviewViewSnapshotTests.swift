import SnapshotTesting
import SwiftUI
import Testing
import XcodeMCPTapUI

@MainActor
@Suite(.snapshots(record: .missing))
struct OverviewViewSnapshotTests {
  static let size = CGSize(width: 640, height: 200)

  @Test
  func notInstalled() {
    let controller = NSHostingController(
      rootView: OverviewView(
        viewModel: .previewNotInstalled(),
        navigate: { _ in }
      )
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }

  @Test
  func running() {
    let controller = NSHostingController(
      rootView: OverviewView(
        viewModel: .previewRunning(),
        navigate: { _ in }
      )
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }
}
