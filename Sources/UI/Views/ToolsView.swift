import SwiftUI
import XcodeMCPTapShared

public struct ToolsView: View {
  @Bindable public var viewModel: StatusViewModel
  @State private var searchText = ""
  @State private var selectedToolID: String?

  public init(viewModel: StatusViewModel) {
    self.viewModel = viewModel
  }

  private var filteredTools: [ToolInfo] {
    let trimmed = searchText.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return viewModel.tools }
    return viewModel.tools.filter { tool in
      tool.name.localizedCaseInsensitiveContains(trimmed)
        || tool.description.localizedCaseInsensitiveContains(trimmed)
    }
  }

  private var groupedTools: [(ToolCategory, [ToolInfo])] {
    let grouped = Dictionary(grouping: filteredTools) { ToolCategory.category(for: $0.name) }
    return ToolCategory.allCases.compactMap { category in
      guard let items = grouped[category], !items.isEmpty else { return nil }
      return (category, items.sorted { $0.name < $1.name })
    }
  }

  private var selectedTool: ToolInfo? {
    guard let id = selectedToolID else { return nil }
    return viewModel.tools.first { $0.id == id }
  }

  public var body: some View {
    Group {
      if viewModel.tools.isEmpty {
        ContentUnavailableView("No tools", systemImage: "wrench.and.screwdriver")
      } else {
        HSplitView {
          toolList
            .frame(minWidth: 240, idealWidth: 300)
          toolDetail
            .frame(minWidth: 280)
        }
      }
    }
    .navigationTitle("Tools")
    .searchable(text: $searchText, placement: .toolbar, prompt: "Search tools")
    .onAppear { selectFirstIfNeeded() }
    .onChange(of: searchText) { _, _ in selectFirstIfNeeded() }
    .onChange(of: viewModel.tools.count) { _, _ in selectFirstIfNeeded() }
  }

  private var toolList: some View {
    List(selection: $selectedToolID) {
      ForEach(groupedTools, id: \.0) { (category, tools) in
        Section {
          ForEach(tools) { tool in
            ToolListRow(tool: tool)
              .tag(tool.id)
          }
        } header: {
          HStack(spacing: 6) {
            Image(systemName: category.systemImage)
              .foregroundStyle(category.tint)
            Text(category.rawValue)
            Spacer()
            Text("\(tools.count)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .overlay {
      if filteredTools.isEmpty {
        ContentUnavailableView.search(text: searchText)
      }
    }
  }

  @ViewBuilder
  private var toolDetail: some View {
    if let tool = selectedTool {
      ToolDetailView(tool: tool)
    } else {
      ContentUnavailableView("Select a tool", systemImage: "wrench.and.screwdriver")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func selectFirstIfNeeded() {
    if let id = selectedToolID, filteredTools.contains(where: { $0.id == id }) {
      return
    }
    selectedToolID = filteredTools.first?.id
  }
}

private struct ToolListRow: View {
  var tool: ToolInfo

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(tool.name)
        .font(.system(.callout, design: .monospaced))
        .fontWeight(.medium)
        .lineLimit(1)
      if !tool.description.isEmpty {
        Text(tool.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 3)
  }
}

private struct ToolDetailView: View {
  var tool: ToolInfo

  private var category: ToolCategory { ToolCategory.category(for: tool.name) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Text(tool.name)
            .font(.system(.title3, design: .monospaced).weight(.semibold))
            .textSelection(.enabled)
          Label(category.rawValue, systemImage: category.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(category.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(category.tint.opacity(0.12), in: Capsule())
          Spacer(minLength: 0)
        }
        if tool.description.isEmpty {
          Text("No description.")
            .font(.callout)
            .foregroundStyle(.tertiary)
        } else {
          Text(tool.description)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

#if DEBUG
#Preview("Populated") {
  ToolsView(viewModel: .previewRunning())
    .frame(width: 820, height: 600)
}

#Preview("Empty") {
  let model = StatusViewModel.previewIdle()
  model.tools = []
  return ToolsView(viewModel: model)
    .frame(width: 820, height: 600)
}
#endif
