import ComposableArchitecture
import SnapshotTesting
import SwiftUI
import Testing
import XcodeMCPTapUI

@MainActor
@Suite
struct OverviewViewSnapshotTests {
  static let size = CGSize(width: 640, height: 260)

  @Test
  func notInstalled() {
    let controller = NSHostingController(
      rootView: OverviewView(
        store: Store(initialState: .previewNotInstalled()) { AppFeature() },
      ),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }

  @Test
  func running() {
    let controller = NSHostingController(
      rootView: OverviewView(
        store: Store(initialState: .previewRunning()) { AppFeature() },
      ),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }

  @Test
  func runningRTL() {
    let controller = NSHostingController(
      rootView: OverviewView(
        store: Store(initialState: .previewRunning()) { AppFeature() },
      )
      .environment(\.layoutDirection, .rightToLeft),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }

  @Test
  func bridgeBooting() {
    let controller = NSHostingController(
      rootView: OverviewView(
        store: Store(initialState: .previewBridgeBooting()) { AppFeature() },
      ),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }

  @Test
  func bridgeFailed() {
    let controller = NSHostingController(
      rootView: OverviewView(
        store: Store(initialState: .previewBridgeFailed()) { AppFeature() },
      ),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }

  @Test
  func bridgeFailedRTL() {
    let controller = NSHostingController(
      rootView: OverviewView(
        store: Store(initialState: .previewBridgeFailed()) { AppFeature() },
      )
      .environment(\.layoutDirection, .rightToLeft),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }
}
