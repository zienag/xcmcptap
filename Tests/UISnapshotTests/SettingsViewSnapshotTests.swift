import ComposableArchitecture
import SnapshotTesting
import SwiftUI
import Testing
import XcodeMCPTapUI

@MainActor
@Suite(.snapshots(record: .missing))
struct SettingsViewSnapshotTests {
  static let size = CGSize(width: 640, height: 380)

  @Test
  func installed() {
    let controller = NSHostingController(
      rootView: SettingsView(
        store: Store(initialState: .previewRunning()) { AppFeature() }
      )
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }

  @Test
  func notInstalled() {
    let controller = NSHostingController(
      rootView: SettingsView(
        store: Store(initialState: .previewNotInstalled()) { AppFeature() }
      )
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }

  @Test
  func copied() {
    var state = AppFeature.State.previewRunning()
    state.settings.copied = true
    let controller = NSHostingController(
      rootView: SettingsView(store: Store(initialState: state) { AppFeature() })
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }

  @Test
  func installedRTL() {
    let controller = NSHostingController(
      rootView: SettingsView(
        store: Store(initialState: .previewRunning()) { AppFeature() }
      )
      .environment(\.layoutDirection, .rightToLeft)
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, as: .image(size: Self.size))
  }
}
