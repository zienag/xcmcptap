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

  /// The Homebrew cask published by `release.yml` must declare the LaunchAgent's
  /// `Label` under `uninstall launchctl:`. Without it, `brew upgrade --cask`
  /// swaps the .app bundle while the old `xcmcptapd` keeps running with the
  /// previous binary mmap'd — so users stay on the old version until they log
  /// out or `bootout` the label by hand.
  ///
  /// The daemon label is intentionally **not** required here: brew would need
  /// `sudo` to tear down a system-domain job, and a GUI-spawned brew has no TTY.
  /// The privileged helper handles daemon teardown over its existing XPC path.
  @Test
  func caskDeclaresAgentLabelForUpgradeReload() throws {
    let packageRoot = packageRootURL()
    let agentLabel = try plistLabel(
      at: packageRoot.appendingPathComponent("App/LaunchAgents/alfred.xcmcptap.plist"),
    )
    let workflow = try String(
      contentsOf: packageRoot.appendingPathComponent(".github/workflows/release.yml"),
      encoding: .utf8,
    )
    let caskBlock = try #require(
      Self.extractCaskHeredoc(from: workflow),
      "Could not locate the cask heredoc in .github/workflows/release.yml",
    )
    #expect(
      caskBlock.contains("uninstall launchctl:"),
      """
      The cask must include an `uninstall launchctl:` stanza so `brew upgrade --cask`
      stops the agent before swapping the bundle. Add it to the heredoc in release.yml.
      """,
    )
    #expect(
      caskBlock.contains("\"\(agentLabel)\""),
      """
      The cask must reference the agent's Label (\"\(agentLabel)\") under `uninstall launchctl:`,
      otherwise the running agent keeps the old binary alive after `brew upgrade --cask`.
      """,
    )
  }

  private static func extractCaskHeredoc(from workflow: String) -> String? {
    let lines = workflow.split(separator: "\n", omittingEmptySubsequences: false)
    guard let startIdx = lines.firstIndex(where: { $0.contains("cask \"xcmcptap\" do") }) else {
      return nil
    }
    guard
      let endOffset = lines[startIdx...]
      .firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "EOF" })
    else {
      return nil
    }
    return lines[startIdx..<endOffset].joined(separator: "\n")
  }

  private func packageRootURL(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
      .deletingLastPathComponent() // Tests/FeatureTests/
      .deletingLastPathComponent() // Tests/
      .deletingLastPathComponent() // package root
  }

  private func plistLabel(at url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    let dict = try #require(plist as? [String: Any])
    return try #require(dict["Label"] as? String)
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
