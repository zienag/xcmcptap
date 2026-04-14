import ComposableArchitecture

@Reducer
public struct SettingsFeature {
  @ObservableState
  public struct State: Equatable {
    public var copiedIntegrationID: String?
    public var showingUninstallConfirm: Bool = false

    public init(copiedIntegrationID: String? = nil, showingUninstallConfirm: Bool = false) {
      self.copiedIntegrationID = copiedIntegrationID
      self.showingUninstallConfirm = showingUninstallConfirm
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case copyResetElapsed(id: String)
    case copyTapped(id: String, command: String)
    case delegate(Delegate)
    case installSystemPathTapped
    case installTapped
    case uninstallCancelled
    case uninstallConfirmed
    case uninstallSystemPathTapped
    case uninstallTapped

    @CasePathable
    public enum Delegate {
      case install
      case installSystemPath
      case uninstall
      case uninstallSystemPath
    }
  }

  public init() {}

  @Dependency(\.continuousClock) var clock
  @Dependency(\.pasteboard) var pasteboard

  enum CancelID { case copyReset }

  public var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .copyTapped(let id, let command):
        state.copiedIntegrationID = id
        let clock = self.clock
        let pasteboard = self.pasteboard
        return .run { send in
          pasteboard.copy(command)
          try await clock.sleep(for: .seconds(1.2))
          await send(.copyResetElapsed(id: id))
        }
        .cancellable(id: CancelID.copyReset, cancelInFlight: true)

      case .copyResetElapsed(let id):
        if state.copiedIntegrationID == id {
          state.copiedIntegrationID = nil
        }
        return .none

      case .installTapped:
        return .send(.delegate(.install))

      case .installSystemPathTapped:
        return .send(.delegate(.installSystemPath))

      case .uninstallSystemPathTapped:
        return .send(.delegate(.uninstallSystemPath))

      case .uninstallTapped:
        state.showingUninstallConfirm = true
        return .none

      case .uninstallConfirmed:
        state.showingUninstallConfirm = false
        return .send(.delegate(.uninstall))

      case .uninstallCancelled:
        state.showingUninstallConfirm = false
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
