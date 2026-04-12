import ComposableArchitecture

@Reducer
public struct SettingsFeature {
  @ObservableState
  public struct State: Equatable {
    public var copied: Bool = false
    public var showingUninstallConfirm: Bool = false

    public init(copied: Bool = false, showingUninstallConfirm: Bool = false) {
      self.copied = copied
      self.showingUninstallConfirm = showingUninstallConfirm
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case copyResetElapsed
    case copyTapped
    case delegate(Delegate)
    case installTapped
    case uninstallCancelled
    case uninstallConfirmed
    case uninstallTapped

    @CasePathable
    public enum Delegate {
      case install
      case uninstall
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

      case .copyTapped:
        state.copied = true
        let command = "claude mcp add --transport stdio xcode -- \(ServiceInstaller.clientLinkPath)"
        let clock = self.clock
        let pasteboard = self.pasteboard
        return .run { send in
          pasteboard.copy(command)
          try await clock.sleep(for: .seconds(1.2))
          await send(.copyResetElapsed)
        }
        .cancellable(id: CancelID.copyReset, cancelInFlight: true)

      case .copyResetElapsed:
        state.copied = false
        return .none

      case .installTapped:
        return .send(.delegate(.install))

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
