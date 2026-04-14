import ComposableArchitecture
import struct Foundation.Date
import XcodeMCPTapShared

@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    public var clientPath: String = ServiceInstaller.clientLinkPath
    public var connections: [ConnectionInfo] = []
    public var health: ServiceHealth?
    public var isInstalled: Bool = false
    public var isOnSystemPath: Bool = false
    public var isServiceRunning: Bool = false
    public var logPath: String = ServiceInstaller.logPath
    public var now: Date = .distantPast
    public var plistPath: String = ServiceInstaller.plistPath
    public var requiresApproval: Bool = false
    public var selection: SidebarItem = .overview
    public var settings: SettingsFeature.State = .init()
    public var systemPath: String = ServiceInstaller.systemLinkPath
    public var tools: ToolsFeature.State = .init()

    public init(
      connections: [ConnectionInfo] = [],
      health: ServiceHealth? = nil,
      isInstalled: Bool = false,
      isOnSystemPath: Bool = false,
      isServiceRunning: Bool = false,
      now: Date = .distantPast,
      requiresApproval: Bool = false,
      selection: SidebarItem = .overview,
      settings: SettingsFeature.State = .init(),
      tools: ToolsFeature.State = .init()
    ) {
      self.connections = connections
      self.health = health
      self.isInstalled = isInstalled
      self.isOnSystemPath = isOnSystemPath
      self.isServiceRunning = isServiceRunning
      self.now = now
      self.requiresApproval = requiresApproval
      self.selection = selection
      self.settings = settings
      self.tools = tools
    }

    public var integrations: [Integration] {
      Integration.all(clientPath: clientPath, onSystemPath: isOnSystemPath)
    }

    public var uptimeText: String? {
      guard let health else { return nil }
      let interval = max(0, now.timeIntervalSince(health.startedAt))
      return formatUptime(interval: interval)
    }

    public var totalMessagesRouted: Int {
      connections.reduce(0) { $0 + $1.messagesRouted }
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case clockTick(Date)
    case installStatusRefreshed(isInstalled: Bool, requiresApproval: Bool, isOnSystemPath: Bool)
    case installTapped
    case openLoginItemsTapped
    case settings(SettingsFeature.Action)
    case statusEvent(StatusEvent)
    case statusFetchFailed
    case statusResponse(StatusResponse)
    case task
    case tools(ToolsFeature.Action)
  }

  public init() {}

  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var nowProvider
  @Dependency(\.serviceInstaller) var serviceInstaller
  @Dependency(\.statusClient) var statusClient

  enum CancelID {
    case clock
    case events
    case poll
  }

  public var body: some Reducer<State, Action> {
    BindingReducer()
    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }
    Scope(state: \.tools, action: \.tools) {
      ToolsFeature()
    }
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .clockTick(let date):
        state.now = date
        return .none

      case .installStatusRefreshed(let isInstalled, let requiresApproval, let isOnSystemPath):
        state.isInstalled = isInstalled
        state.requiresApproval = requiresApproval
        state.isOnSystemPath = isOnSystemPath
        return .none

      case .installTapped:
        return install(&state)

      case .openLoginItemsTapped:
        serviceInstaller.openLoginItems()
        return .none

      case .settings(.delegate(.install)):
        return install(&state)

      case .settings(.delegate(.installSystemPath)):
        serviceInstaller.installSystemPath()
        state.isOnSystemPath = serviceInstaller.isOnSystemPath()
        return .none

      case .settings(.delegate(.uninstallSystemPath)):
        serviceInstaller.uninstallSystemPath()
        state.isOnSystemPath = serviceInstaller.isOnSystemPath()
        return .none

      case .settings(.delegate(.uninstall)):
        serviceInstaller.uninstall()
        state.isInstalled = false
        state.requiresApproval = false
        state.isOnSystemPath = false
        state.isServiceRunning = false
        state.connections = []
        state.health = nil
        return .none

      case .settings:
        return .none

      case .statusEvent(let event):
        switch event.kind {
        case .connectionOpened:
          if !state.connections.contains(where: { $0.id == event.connection.id }) {
            state.connections.append(event.connection)
          }
        case .connectionClosed:
          state.connections.removeAll { $0.id == event.connection.id }
        }
        return .none

      case .statusFetchFailed:
        state.connections = []
        state.health = nil
        state.tools.tools = []
        state.isServiceRunning = false
        return .none

      case .statusResponse(let response):
        state.connections = response.connections
        state.health = response.health
        state.tools.tools = response.tools
        state.isServiceRunning = true
        return .send(.tools(.toolsChangedInternal))

      case .task:
        state.now = nowProvider
        state.isInstalled = serviceInstaller.isInstalled()
        state.requiresApproval = serviceInstaller.requiresApproval()
        state.isOnSystemPath = serviceInstaller.isOnSystemPath()
        return .merge(
          poll(),
          subscribeToEvents(),
          tickClock()
        )

      case .tools:
        return .none
      }
    }
  }

  private func install(_ state: inout State) -> Effect<Action> {
    serviceInstaller.install()
    state.isInstalled = serviceInstaller.isInstalled()
    state.requiresApproval = serviceInstaller.requiresApproval()
    state.isOnSystemPath = serviceInstaller.isOnSystemPath()
    let clock = self.clock
    let statusClient = self.statusClient
    let installer = self.serviceInstaller
    return .run { send in
      try? await clock.sleep(for: .seconds(1))
      await send(
        .installStatusRefreshed(
          isInstalled: installer.isInstalled(),
          requiresApproval: installer.requiresApproval(),
          isOnSystemPath: installer.isOnSystemPath()
        )
      )
      await Self.fetchOnce(statusClient: statusClient, send: send)
    }
  }

  private func poll() -> Effect<Action> {
    let clock = self.clock
    let statusClient = self.statusClient
    let installer = self.serviceInstaller
    return .run { send in
      while !Task.isCancelled {
        await send(
          .installStatusRefreshed(
            isInstalled: installer.isInstalled(),
            requiresApproval: installer.requiresApproval(),
            isOnSystemPath: installer.isOnSystemPath()
          )
        )
        await Self.fetchOnce(statusClient: statusClient, send: send)
        try? await clock.sleep(for: .seconds(2))
      }
    }
    .cancellable(id: CancelID.poll, cancelInFlight: true)
  }

  private static func fetchOnce(statusClient: StatusClient, send: Send<Action>) async {
    do {
      let response = try await statusClient.fetch()
      await send(.statusResponse(response))
    } catch {
      await send(.statusFetchFailed)
    }
  }

  private func subscribeToEvents() -> Effect<Action> {
    let statusClient = self.statusClient
    return .run { send in
      for await event in statusClient.events() {
        await send(.statusEvent(event))
      }
    }
    .cancellable(id: CancelID.events, cancelInFlight: true)
  }

  private func tickClock() -> Effect<Action> {
    let clock = self.clock
    return .run { send in
      for await _ in clock.timer(interval: .seconds(1)) {
        @Dependency(\.date.now) var now
        await send(.clockTick(now))
      }
    }
    .cancellable(id: CancelID.clock, cancelInFlight: true)
  }
}
