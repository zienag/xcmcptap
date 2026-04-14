import XCTest

/// End-to-end coverage for the user-level LaunchAgent install flow.
///
/// This is intentionally a *real* XCUITest: it launches the packaged .app,
/// drives the Settings pane, registers the LaunchAgent via SMAppService,
/// and asserts that `xcmcptapd` actually came up (sidebar shows
/// "Service running"). If the bundled agent plist has a bad `BundleProgram`
/// path — launchd fails to spawn with `EX_CONFIG (78)` and the sidebar stays
/// stuck on "Service stopped" — the test fails.
///
/// The daemon-install flow (`/usr/local/bin` symlink via `SMAppService.daemon`)
/// is deliberately not covered here: it requires user approval in
/// System Settings > Login Items (Touch ID / admin password), which XCUITest
/// cannot automate without a user-approved MDM profile.
@MainActor
final class ServiceInstallUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testInstallingAgentBringsServiceUp() throws {
    let app = XCUIApplication()
    app.launch()
    addTeardownBlock {
      self.uninstallIfInstalled(app: app)
      app.terminate()
    }

    navigateToSettings(app: app)
    uninstallIfInstalled(app: app)

    let installButton = app.buttons["Install service"]
    XCTAssertTrue(installButton.waitForExistence(timeout: 3), "'Install service' button not visible")
    installButton.click()

    let runningLabel = app.staticTexts["Service running"]
    XCTAssertTrue(
      runningLabel.waitForExistence(timeout: 10),
      "xcmcptapd did not come up within 10s — most likely a broken agent plist "
        + "(e.g. BundleProgram resolving to a path launchd can't find, EX_CONFIG)"
    )
  }

  // MARK: - Helpers

  private func navigateToSettings(app: XCUIApplication) {
    let settingsRow = app.outlines.staticTexts["Settings"]
    XCTAssertTrue(settingsRow.waitForExistence(timeout: 3), "Settings sidebar row not found")
    settingsRow.click()
  }

  private func uninstallIfInstalled(app: XCUIApplication) {
    let uninstallButton = app.buttons["Uninstall"]
    guard uninstallButton.waitForExistence(timeout: 1.0) else { return }
    uninstallButton.click()
    // Confirmation dialog — "Uninstall" is the destructive confirm button.
    let confirm = app.sheets.buttons["Uninstall"].firstMatch
    if confirm.waitForExistence(timeout: 2.0) {
      confirm.click()
    }
    // Wait for UI to flip back to "Install service"
    _ = app.buttons["Install service"].waitForExistence(timeout: 3.0)
  }
}
