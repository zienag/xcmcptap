import AppKit
import ComposableArchitecture
import Foundation

@DependencyClient
public struct ConfigRevealerClient: Sendable {
  public var reveal: @Sendable (_ path: String) -> Void
}

extension ConfigRevealerClient: DependencyKey {
  public static let liveValue = ConfigRevealerClient(
    reveal: { path in
      let expanded = (path as NSString).expandingTildeInPath
      let url = URL(fileURLWithPath: expanded)
      let parent = url.deletingLastPathComponent()
      let fm = FileManager.default

      if !fm.fileExists(atPath: parent.path) {
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
      }
      if !fm.fileExists(atPath: expanded) {
        fm.createFile(atPath: expanded, contents: nil)
      }
      NSWorkspace.shared.activateFileViewerSelecting([url])
    },
  )

  public static let testValue = ConfigRevealerClient()
}

public extension DependencyValues {
  var configRevealer: ConfigRevealerClient {
    get { self[ConfigRevealerClient.self] }
    set { self[ConfigRevealerClient.self] = newValue }
  }
}
