import ComposableArchitecture
import SwiftUI
import XcodeMCPTapShared

public struct ToolsView: View {
  @Bindable public var store: StoreOf<ToolsFeature>

  private enum Layout {
    static let toolListWidth: CGFloat = 280
  }

  public init(store: StoreOf<ToolsFeature>) {
    self.store = store
  }

  public var body: some View {
    Group {
      if store.tools.isEmpty {
        ContentUnavailableView("No tools", systemImage: "wrench.and.screwdriver")
      } else {
        HStack(spacing: 0) {
          toolList
            .frame(width: Layout.toolListWidth)
          Divider()
          toolDetail
            .frame(maxWidth: .infinity)
        }
      }
    }
    .navigationTitle("Tools")
    .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search tools")
    .onAppear { store.send(.onAppear) }
  }

  private var toolList: some View {
    List(selection: $store.selectedToolID) {
      ForEach(store.groupedTools, id: \.0) { (category, tools) in
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
      if store.filteredTools.isEmpty {
        ContentUnavailableView.search(text: store.searchText)
      }
    }
  }

  @ViewBuilder
  private var toolDetail: some View {
    if let tool = store.selectedTool {
      ToolDetailView(tool: tool)
    } else {
      ContentUnavailableView("Select a tool", systemImage: "wrench.and.screwdriver")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
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
  ToolsView(
    store: Store(
      initialState: ToolsFeature.State(tools: AppFeature.State.sampleTools)
    ) { ToolsFeature() }
  )
  .frame(width: 820, height: 600)
}

#Preview("Empty") {
  ToolsView(store: Store(initialState: ToolsFeature.State()) { ToolsFeature() })
    .frame(width: 820, height: 600)
}
#endif
