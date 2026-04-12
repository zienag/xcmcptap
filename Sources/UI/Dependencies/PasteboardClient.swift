import AppKit
import ComposableArchitecture

@DependencyClient
public struct PasteboardClient: Sendable {
  public var copy: @Sendable (String) -> Void
}

extension PasteboardClient: DependencyKey {
  public static let liveValue = PasteboardClient(
    copy: { string in
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(string, forType: .string)
    }
  )

  public static let testValue = PasteboardClient()
}

extension DependencyValues {
  public var pasteboard: PasteboardClient {
    get { self[PasteboardClient.self] }
    set { self[PasteboardClient.self] = newValue }
  }
}
