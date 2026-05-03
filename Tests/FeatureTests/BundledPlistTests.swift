import Foundation
import Testing

/// Sanity check the LaunchAgent / LaunchDaemon plist templates that the
/// app's pre-build script substitutes and copies into
/// `Contents/Library/LaunchAgents` / `LaunchDaemons` of the .app bundle.
///
/// `BundleProgram` must be relative to the **bundle root** (i.e.
/// `Contents/MacOS/<tool>`). launchd resolves it that way, not relative
/// to `Contents/`. A value like `"MacOS/xcmcptapd"` silently becomes
/// `/Applications/<App>.app/MacOS/xcmcptapd` — which doesn't exist —
/// and launchd fails with `EX_CONFIG (78)` on spawn. The daemon or
/// agent then never starts, with no user-visible error.
struct BundledPlistTests {
  @Test
  func agentTemplatePointsIntoContentsMacOS() throws {
    try assertBundleProgram(
      relativePath: "BuildConfig/agent.plist.template",
      expectedBinary: "xcmcptapd",
    )
  }

  @Test
  func helperDaemonTemplatePointsIntoContentsMacOS() throws {
    try assertBundleProgram(
      relativePath: "BuildConfig/helper.plist.template",
      expectedBinary: "xcmcptap-helper",
    )
  }

  /// The Homebrew cask published by `release.yml` must declare the
  /// (Release-variant) LaunchAgent's `Label` under `uninstall launchctl:`.
  /// Without it, `brew upgrade --cask` swaps the .app bundle while the
  /// old `xcmcptapd` keeps running with the previous binary mmap'd — so
  /// users stay on the old version until they log out or `bootout` the
  /// label by hand.
  ///
  /// The daemon label is intentionally **not** required here: brew would
  /// need `sudo` to tear down a system-domain job, and a GUI-spawned
  /// brew has no TTY. The privileged helper handles daemon teardown over
  /// its existing XPC path.
  @Test
  func caskDeclaresAgentLabelForUpgradeReload() throws {
    let releaseLabel = try releaseServiceName()
    let workflow = try String(
      contentsOf: packageRootURL().appendingPathComponent(".github/workflows/release.yml"),
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
      caskBlock.contains("\"\(releaseLabel)\""),
      """
      The cask must reference the agent's Label (\"\(releaseLabel)\") under `uninstall launchctl:`,
      otherwise the running agent keeps the old binary alive after `brew upgrade --cask`.
      """,
    )
  }

  // MARK: - Helpers

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

  /// Reads the Release `XCMCPTAP_SERVICE_NAME` from `BuildConfig/Identity.xcconfig`.
  /// Used to compute the LaunchAgent label that the cask must reference.
  /// Splits on the first ` = ` (with spaces) — the qualifier `[config=Release]`
  /// uses `=` without surrounding spaces, so this avoids misparsing.
  private func releaseServiceName() throws -> String {
    let url = packageRootURL().appendingPathComponent("BuildConfig/Identity.xcconfig")
    let xcconfig = try String(contentsOf: url, encoding: .utf8)
    let prefix = "XCMCPTAP_SERVICE_NAME[config=Release]"
    let separator = " = "
    for line in xcconfig.split(separator: "\n") {
      guard line.hasPrefix(prefix) else { continue }
      guard let range = line.range(of: separator) else { continue }
      return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
    throw IdentityXcconfigError.releaseServiceNameMissing
  }

  private func assertBundleProgram(
    relativePath: String,
    expectedBinary: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    filePath: String = #filePath,
  ) throws {
    let plistURL = packageRootURL(filePath: filePath).appendingPathComponent(relativePath)
    // Templates carry `__SERVICE_NAME__` placeholders. Substitute a real
    // identifier so PropertyListSerialization can parse them — the value
    // only affects keys outside `BundleProgram`, which is what we assert.
    let raw = try String(contentsOf: plistURL, encoding: .utf8)
    let substituted = raw.replacingOccurrences(of: "__SERVICE_NAME__", with: "test.identifier")
    guard let data = substituted.data(using: .utf8) else {
      Issue.record("Could not encode substituted template at \(relativePath)")
      return
    }
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    let dict = try #require(plist as? [String: Any], sourceLocation: sourceLocation)
    let bundleProgram = try #require(dict["BundleProgram"] as? String, sourceLocation: sourceLocation)

    #expect(
      bundleProgram == "Contents/MacOS/\(expectedBinary)",
      "BundleProgram must be rooted at 'Contents/MacOS/' — launchd resolves it relative to the bundle root, not Contents/.",
      sourceLocation: sourceLocation,
    )
  }

  private enum IdentityXcconfigError: Error {
    case releaseServiceNameMissing
  }
}
