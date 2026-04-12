import ComposableArchitecture
import Testing
import XcodeMCPTapShared
import XcodeMCPTapUI

@MainActor
struct ToolsFeatureTests {
  private static let tools: [ToolInfo] = [
    .init(name: "BuildProject", description: "Build"),
    .init(name: "XcodeRead", description: "Read file"),
    .init(name: "XcodeListWindows", description: "Windows"),
  ]

  @Test
  func onAppearSelectsFirstTool() async {
    let store = TestStore(
      initialState: ToolsFeature.State(tools: Self.tools)
    ) {
      ToolsFeature()
    }

    await store.send(.onAppear) {
      $0.selectedToolID = "BuildProject"
    }
  }

  @Test
  func onAppearKeepsValidSelection() async {
    let store = TestStore(
      initialState: ToolsFeature.State(
        selectedToolID: "XcodeRead",
        tools: Self.tools
      )
    ) {
      ToolsFeature()
    }

    await store.send(.onAppear)
  }

  @Test
  func searchTextChangeReselectsIfCurrentFiltersOut() async {
    let store = TestStore(
      initialState: ToolsFeature.State(
        selectedToolID: "XcodeRead",
        tools: Self.tools
      )
    ) {
      ToolsFeature()
    }

    await store.send(\.binding.searchText, "build") {
      $0.searchText = "build"
      $0.selectedToolID = "BuildProject"
    }
  }

  @Test
  func searchTextChangeKeepsSelectionIfStillMatches() async {
    let store = TestStore(
      initialState: ToolsFeature.State(
        selectedToolID: "XcodeRead",
        tools: Self.tools
      )
    ) {
      ToolsFeature()
    }

    await store.send(\.binding.searchText, "xcode") {
      $0.searchText = "xcode"
    }
  }

  @Test
  func searchNoMatchClearsSelection() async {
    let store = TestStore(
      initialState: ToolsFeature.State(
        selectedToolID: "BuildProject",
        tools: Self.tools
      )
    ) {
      ToolsFeature()
    }

    await store.send(\.binding.searchText, "zzz") {
      $0.searchText = "zzz"
      $0.selectedToolID = nil
    }
  }

  @Test
  func toolsChangedInternalReselectsFirstWhenCurrentGone() async {
    let store = TestStore(
      initialState: ToolsFeature.State(
        selectedToolID: "GoneTool",
        tools: Self.tools
      )
    ) {
      ToolsFeature()
    }

    await store.send(.toolsChangedInternal) {
      $0.selectedToolID = "BuildProject"
    }
  }

  @Test
  func filteredToolsIsCaseInsensitive() {
    let state = ToolsFeature.State(searchText: "BUILD", tools: Self.tools)
    #expect(state.filteredTools.map(\.name) == ["BuildProject"])
  }

  @Test
  func groupedToolsPartitionsByCategory() {
    let state = ToolsFeature.State(tools: Self.tools)
    let grouped = state.groupedTools
    #expect(grouped.map(\.0) == [.build, .files, .workspace])
  }
}
