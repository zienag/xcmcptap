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

    await store.send(.copyTapped) {
      $0.copied = true
    }

    await clock.advance(by: .seconds(1.2))

    await store.receive(\.copyResetElapsed) {
      $0.copied = false
    }

    #expect(copiedStrings.value.count == 1)
    #expect(copiedStrings.value.first?.hasPrefix("claude mcp add --transport stdio xcode -- ") == true)
  }

  @Test
  func copyTappedTwiceCancelsInFlightReset() async {
    let clock = TestClock()

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.pasteboard.copy = { _ in }
    }

    await store.send(.copyTapped) {
      $0.copied = true
    }

    await clock.advance(by: .seconds(0.6))

    await store.send(.copyTapped)

    await clock.advance(by: .seconds(1.2))

    await store.receive(\.copyResetElapsed) {
      $0.copied = false
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
      initialState: SettingsFeature.State(showingUninstallConfirm: true)
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
}
