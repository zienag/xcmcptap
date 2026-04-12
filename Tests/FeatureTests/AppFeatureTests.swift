import ComposableArchitecture
import struct Foundation.Date
import struct Foundation.UUID
import Testing
import XcodeMCPTapShared
import XcodeMCPTapUI

private let testNow = Date(timeIntervalSince1970: 1_700_000_000)
private let testConnection = ConnectionInfo(
  id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
  connectedAt: testNow.addingTimeInterval(-10),
  messagesRouted: 5,
  lastActivityAt: testNow.addingTimeInterval(-1),
  bridgePID: 42
)
private let testHealth = ServiceHealth(
  startedAt: testNow.addingTimeInterval(-60),
  totalConnectionsServed: 3,
  activeConnectionCount: 1
)
private let testTool = ToolInfo(name: "BuildProject", description: "Build")

@MainActor
struct AppFeatureTests {

  @Test
  func statusResponsePopulatesStateAndNotifiesTools() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    let response = StatusResponse(
      connections: [testConnection],
      health: testHealth,
      tools: [testTool]
    )

    await store.send(.statusResponse(response)) {
      $0.connections = [testConnection]
      $0.health = testHealth
      $0.tools.tools = [testTool]
      $0.isServiceRunning = true
    }

    await store.receive(\.tools.toolsChangedInternal) {
      $0.tools.selectedToolID = testTool.id
    }
  }

  @Test
  func statusFetchFailedClearsState() async {
    var initial = AppFeature.State()
    initial.connections = [testConnection]
    initial.health = testHealth
    initial.tools.tools = [testTool]
    initial.isServiceRunning = true

    let store = TestStore(initialState: initial) {
      AppFeature()
    }

    await store.send(.statusFetchFailed) {
      $0.connections = []
      $0.health = nil
      $0.tools.tools = []
      $0.isServiceRunning = false
    }
  }

  @Test
  func connectionOpenedEventAppends() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.statusEvent(StatusEvent(kind: .connectionOpened, connection: testConnection))) {
      $0.connections = [testConnection]
    }
  }

  @Test
  func connectionOpenedEventIsIdempotent() async {
    var initial = AppFeature.State()
    initial.connections = [testConnection]

    let store = TestStore(initialState: initial) {
      AppFeature()
    }

    await store.send(.statusEvent(StatusEvent(kind: .connectionOpened, connection: testConnection)))
  }

  @Test
  func connectionClosedEventRemoves() async {
    var initial = AppFeature.State()
    initial.connections = [testConnection]

    let store = TestStore(initialState: initial) {
      AppFeature()
    }

    await store.send(.statusEvent(StatusEvent(kind: .connectionClosed, connection: testConnection))) {
      $0.connections = []
    }
  }

  @Test
  func clockTickUpdatesNow() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.clockTick(testNow)) {
      $0.now = testNow
    }
  }

  @Test
  func installTappedCallsInstallerAndRefetches() async {
    let clock = TestClock()
    let installCalls = LockIsolated(0)
    let response = StatusResponse(
      connections: [],
      health: testHealth,
      tools: []
    )

    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.statusClient.fetch = { response }
      $0.serviceInstaller.install = { installCalls.withValue { $0 += 1 } }
    }

    await store.send(.installTapped) {
      $0.isInstalled = true
    }

    #expect(installCalls.value == 1)

    await clock.advance(by: .seconds(1))

    await store.receive(\.statusResponse) {
      $0.health = testHealth
      $0.isServiceRunning = true
    }

    await store.receive(\.tools.toolsChangedInternal)
  }

  @Test
  func uninstallDelegateCallsInstallerAndClearsState() async {
    let uninstallCalls = LockIsolated(0)
    var initial = AppFeature.State(
      connections: [testConnection],
      health: testHealth,
      isInstalled: true,
      isServiceRunning: true
    )
    initial.tools.tools = [testTool]

    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.serviceInstaller.uninstall = { uninstallCalls.withValue { $0 += 1 } }
    }

    await store.send(.settings(.delegate(.uninstall))) {
      $0.connections = []
      $0.health = nil
      $0.isInstalled = false
      $0.isServiceRunning = false
    }

    #expect(uninstallCalls.value == 1)
  }

  @Test
  func settingsInstallDelegateEquivalentToInstallTapped() async {
    let clock = TestClock()
    let installCalls = LockIsolated(0)

    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.statusClient.fetch = {
        StatusResponse(connections: [], health: testHealth, tools: [])
      }
      $0.serviceInstaller.install = { installCalls.withValue { $0 += 1 } }
    }

    await store.send(.settings(.delegate(.install))) {
      $0.isInstalled = true
    }

    #expect(installCalls.value == 1)

    await clock.advance(by: .seconds(1))

    await store.receive(\.statusResponse) {
      $0.health = testHealth
      $0.isServiceRunning = true
    }

    await store.receive(\.tools.toolsChangedInternal)
  }
}
