import ComposableArchitecture
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
        store: Store(initialState: .previewNotInstalled()) { AppFeature() }
      )
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }

  @Test
  func running() {
    let controller = NSHostingController(
      rootView: OverviewView(
        store: Store(initialState: .previewRunning()) { AppFeature() }
      )
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }

  @Test
  func runningRTL() {
    let controller = NSHostingController(
      rootView: OverviewView(
        store: Store(initialState: .previewRunning()) { AppFeature() }
      )
      .environment(\.layoutDirection, .rightToLeft)
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }
}
