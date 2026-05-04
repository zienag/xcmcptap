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

  /// The cask must run `xcmcptap uninstall` from `uninstall_preflight` so
  /// `brew upgrade --cask` stops the running agent before swapping the
  /// bundle — otherwise the old `xcmcptapd` keeps the previous binary
  /// mmap'd and users stay on the old version until they log out or
  /// `bootout` the label by hand.
  ///
  /// We enforce the preflight (and the subcommand it invokes) instead of
  /// the older `uninstall launchctl:` directive: the directive used to
  /// probe both user and system launchd domains, prompting for `sudo`
  /// even though the agent only ever lives in the user domain. The
  /// preflight's `xcmcptap uninstall` calls `SMAppService.agent.unregister()`
  /// which stops the running job cleanly under the user's login session.
  @Test
  func caskTearsDownAgentBeforeBundleSwap() throws {
    let workflow = try String(
      contentsOf: packageRootURL().appendingPathComponent(".github/workflows/release.yml"),
      encoding: .utf8,
    )
    let caskBlock = try #require(
      Self.extractCaskHeredoc(from: workflow),
      "Could not locate the cask heredoc in .github/workflows/release.yml",
    )
    #expect(
      caskBlock.contains("uninstall_preflight do"),
      """
      The cask must include an `uninstall_preflight do … end` block in the heredoc
      in release.yml — that's how the running agent gets bootout'd before brew swaps
      the .app bundle.
      """,
    )
    #expect(
      caskBlock.contains("args: [\"uninstall\"]"),
      """
      `uninstall_preflight` must invoke the bundled `xcmcptap` binary with the
      `uninstall` subcommand so `SMAppService.agent.unregister()` runs against
      the still-on-disk bundle.
      """,
    )
    #expect(
      !caskBlock.contains("uninstall launchctl:"),
      """
      Drop the legacy `uninstall launchctl:` directive — it probes the system
      launchd domain too, prompting for `sudo` during normal `brew upgrade`. The
      `uninstall_preflight` flow above replaces it.
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

}
