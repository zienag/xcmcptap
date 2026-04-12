import AppKit
import SwiftUI

@MainActor
func hostedInWindow(_ view: some View, size: CGSize) -> NSHostingController<AnyView> {
  let controller = NSHostingController(rootView: AnyView(view))
  controller.view.frame = CGRect(origin: .zero, size: size)
  let window = NSWindow(
    contentRect: CGRect(origin: .zero, size: size),
    styleMask: [.titled, .closable, .resizable],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.layoutIfNeeded()
  return controller
}
