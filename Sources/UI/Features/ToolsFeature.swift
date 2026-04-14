import ComposableArchitecture
import XcodeMCPTapShared

@Reducer
public struct ToolsFeature {
  @ObservableState
  public struct State: Equatable {
    public var searchText: String = ""
    public var selectedToolID: String?
    public var tools: [ToolInfo] = []

    public init(
      searchText: String = "",
      selectedToolID: String? = nil,
      tools: [ToolInfo] = [],
    ) {
      self.searchText = searchText
      self.selectedToolID = selectedToolID
      self.tools = tools
    }

    public var filteredTools: [ToolInfo] {
      let trimmed = searchText.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { return tools }
      return tools.filter {
        $0.name.localizedCaseInsensitiveContains(trimmed)
          || $0.description.localizedCaseInsensitiveContains(trimmed)
      }
    }

    public var groupedTools: [(ToolCategory, [ToolInfo])] {
      let grouped = Dictionary(grouping: filteredTools) { ToolCategory.category(for: $0.name) }
      return ToolCategory.allCases.compactMap { category in
        guard let items = grouped[category], !items.isEmpty else { return nil }
        return (category, items.sorted { $0.name < $1.name })
      }
    }

    public var selectedTool: ToolInfo? {
      guard let id = selectedToolID else { return nil }
      return tools.first { $0.id == id }
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case searchTextChangedInternal
    case toolsChangedInternal
  }

  public init() {}

  public var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.searchText):
        selectFirstIfNeeded(&state)
      case .binding:
        .none
      case .onAppear, .searchTextChangedInternal, .toolsChangedInternal:
        selectFirstIfNeeded(&state)
      }
    }
  }

  private func selectFirstIfNeeded(_ state: inout State) -> Effect<Action> {
    if let id = state.selectedToolID, state.filteredTools.contains(where: { $0.id == id }) {
      return .none
    }
    state.selectedToolID = state.filteredTools.first?.id
    return .none
  }
}
