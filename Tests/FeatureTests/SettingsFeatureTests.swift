import ComposableArchitecture
import Testing
import XcodeMCPTapUI

@MainActor
struct SettingsFeatureTests {
  @Test
  func copyTappedCopiesAndResetsAfterDelay() async {
    let clock = TestClock()
    let copiedStrings = LockIsolated<[String]>([])

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.pasteboard.copy = { string in
        copiedStrings.withValue { $0.append(string) }
      }
    }

    let command = "claude mcp add --transport stdio xcode -- /tmp/xcmcptap"
    await store.send(.copyTapped(id: "claude", command: command)) {
      $0.copiedIntegrationID = "claude"
    }

    await clock.advance(by: .seconds(1.2))

    await store.receive(\.copyResetElapsed) {
      $0.copiedIntegrationID = nil
    }

    #expect(copiedStrings.value == [command])
  }

  @Test
  func copyTappedDifferentIntegrationSwitchesHighlightAndCancelsPreviousReset() async {
    let clock = TestClock()

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.pasteboard.copy = { _ in }
    }

    await store.send(.copyTapped(id: "claude", command: "claude-cmd")) {
      $0.copiedIntegrationID = "claude"
    }

    await clock.advance(by: .seconds(0.6))

    await store.send(.copyTapped(id: "codex", command: "codex-cmd")) {
      $0.copiedIntegrationID = "codex"
    }

    await clock.advance(by: .seconds(1.2))

    await store.receive(\.copyResetElapsed) {
      $0.copiedIntegrationID = nil
    }
  }

  @Test
  func uninstallFlowShowsConfirmThenDelegates() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.uninstallTapped) {
      $0.showingUninstallConfirm = true
    }

    await store.send(.uninstallConfirmed) {
      $0.showingUninstallConfirm = false
    }

    await store.receive(\.delegate.uninstall)
  }

  @Test
  func uninstallCancelledHidesConfirm() async {
    let store = TestStore(
      initialState: SettingsFeature.State(showingUninstallConfirm: true),
    ) {
      SettingsFeature()
    }

    await store.send(.uninstallCancelled) {
      $0.showingUninstallConfirm = false
    }
  }

  @Test
  func installTappedEmitsDelegate() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.installTapped)
    await store.receive(\.delegate.install)
  }

  @Test
  func installSystemPathTappedEmitsDelegate() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.installSystemPathTapped)
    await store.receive(\.delegate.installSystemPath)
  }

  @Test
  func uninstallSystemPathTappedEmitsDelegate() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.uninstallSystemPathTapped)
    await store.receive(\.delegate.uninstallSystemPath)
  }
}
