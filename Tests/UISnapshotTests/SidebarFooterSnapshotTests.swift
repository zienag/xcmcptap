import SnapshotTesting
import SwiftUI
import Testing
import XcodeMCPTapUI

@MainActor
@Suite
struct SidebarFooterSnapshotTests {
  static let size = CGSize(width: 240, height: 44)

  @Test
  func running() {
    let controller = NSHostingController(
      rootView: SidebarFooter(isServiceRunning: true, isInstalled: true),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }

  @Test
  func stopped() {
    let controller = NSHostingController(
      rootView: SidebarFooter(isServiceRunning: false, isInstalled: true),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }

  @Test
  func notInstalled() {
    let controller = NSHostingController(
      rootView: SidebarFooter(isServiceRunning: false, isInstalled: false),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }

  @Test
  func runningRTL() {
    let controller = NSHostingController(
      rootView: SidebarFooter(isServiceRunning: true, isInstalled: true)
        .environment(\.layoutDirection, .rightToLeft),
    )
    controller.view.frame = CGRect(origin: .zero, size: Self.size)
    assertSnapshot(of: controller, size: Self.size)
  }
}
