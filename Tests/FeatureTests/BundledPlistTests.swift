import Foundation
import Testing

/// Sanity check that every plist the app ships under `Contents/Library/...`
/// uses `BundleProgram` relative to the **bundle root** (i.e. `Contents/MacOS/<tool>`).
///
/// launchd resolves `BundleProgram` against the bundle root, not `Contents/`.
/// A value like `"MacOS/xcmcptapd"` silently becomes
/// `/Applications/Xcode MCP Tap.app/MacOS/xcmcptapd` — which doesn't exist —
/// and launchd fails with `EX_CONFIG (78)` on spawn. The daemon or agent then
/// just never starts, with no user-visible error.
struct BundledPlistTests {
  @Test
  func agentPlistPointsIntoContentsMacOS() throws {
    try assertBundleProgram(
      relativePath: "App/LaunchAgents/alfred.xcmcptap.plist",
      expectedBinary: "xcmcptapd",
    )
  }

  @Test
  func helperDaemonPlistPointsIntoContentsMacOS() throws {
    try assertBundleProgram(
      relativePath: "App/LaunchDaemons/alfred.xcmcptap.helper.plist",
      expectedBinary: "xcmcptap-helper",
    )
  }

  private func assertBundleProgram(
    relativePath: String,
    expectedBinary: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    filePath: String = #filePath,
  ) throws {
    let packageRoot = URL(fileURLWithPath: filePath)
      .deletingLastPathComponent() // Tests/FeatureTests/
      .deletingLastPathComponent() // Tests/
      .deletingLastPathComponent() // package root
    let plistURL = packageRoot.appendingPathComponent(relativePath)
    let data = try Data(contentsOf: plistURL)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    let dict = try #require(plist as? [String: Any], sourceLocation: sourceLocation)
    let bundleProgram = try #require(dict["BundleProgram"] as? String, sourceLocation: sourceLocation)

    #expect(
      bundleProgram == "Contents/MacOS/\(expectedBinary)",
      "BundleProgram must be rooted at 'Contents/MacOS/' — launchd resolves it relative to the bundle root, not Contents/.",
      sourceLocation: sourceLocation,
    )
  }
}
