import SwiftUI
import XcodeMCPTapShared

struct ContentView: View {
  @Bindable var viewModel: StatusViewModel
  @SceneStorage("sidebar.selection") private var rawSelection: String = SidebarItem.overview.rawValue
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  private var selection: Binding<SidebarItem> {
    Binding(
      get: { SidebarItem(rawValue: rawSelection) ?? .overview },
      set: { rawSelection = $0.rawValue }
    )
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebar
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    } detail: {
      detail
        .navigationSplitViewColumnWidth(min: 440, ideal: 560)
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 680, minHeight: 400)
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    List(selection: selection) {
      ForEach(SidebarItem.allCases) { item in
        NavigationLink(value: item) {
          Label(item.title, systemImage: item.systemImage)
        }
        .badge(badge(for: item))
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Xcode MCP Tap")
    .safeAreaInset(edge: .bottom, spacing: 0) {
      sidebarFooter
    }
  }

  private var sidebarFooter: some View {
    HStack(spacing: 10) {
      StatusDot(running: viewModel.isServiceRunning)
      VStack(alignment: .leading, spacing: 1) {
        Text(viewModel.isServiceRunning ? "Service running" : "Service stopped")
          .font(.caption.weight(.medium))
        if viewModel.isServiceRunning, let health = viewModel.health {
          Text("Up \(formatUptime(since: health.startedAt))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        } else if !viewModel.isInstalled {
          Text("Not installed")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
    .overlay(alignment: .top) {
      Divider()
    }
  }

  private func badge(for item: SidebarItem) -> Int {
    switch item {
    case .overview: 0
    case .tools: viewModel.tools.count
    case .connections: viewModel.connections.count
    case .settings: 0
    }
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    switch selection.wrappedValue {
    case .overview:
      OverviewView(viewModel: viewModel) { selection.wrappedValue = $0 }
    case .tools:
      ToolsView(viewModel: viewModel)
    case .connections:
      ConnectionsView(viewModel: viewModel)
    case .settings:
      SettingsView(viewModel: viewModel)
    }
  }
}

// MARK: - Sidebar Item

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
  case overview
  case tools
  case connections
  case settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .overview: "Overview"
    case .tools: "Tools"
    case .connections: "Connections"
    case .settings: "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "gauge.with.dots.needle.bottom.50percent"
    case .tools: "wrench.and.screwdriver"
    case .connections: "personalhotspot"
    case .settings: "gearshape"
    }
  }
}

// MARK: - Status Dot

struct StatusDot: View {
  var running: Bool
  @State private var pulse = false

  var body: some View {
    ZStack {
      if running {
        Circle()
          .stroke(Color.green.opacity(0.6), lineWidth: 2)
          .frame(width: 10, height: 10)
          .scaleEffect(pulse ? 2.4 : 1.0)
          .opacity(pulse ? 0 : 0.7)
      }
      Circle()
        .fill(running ? Color.green : Color.red.opacity(0.85))
        .frame(width: 8, height: 8)
        .shadow(color: (running ? Color.green : Color.red).opacity(0.5), radius: 3)
    }
    .frame(width: 14, height: 14)
    .onAppear {
      guard running else { return }
      withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
        pulse = true
      }
    }
    .onChange(of: running) { _, newValue in
      pulse = false
      guard newValue else { return }
      withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
        pulse = true
      }
    }
  }
}

// MARK: - Tool category

enum ToolCategory: String, CaseIterable, Hashable, Identifiable {
  case build = "Build & Run"
  case files = "Files"
  case workspace = "Workspace"
  case other = "Other"

  var id: String { rawValue }

  var systemImage: String {
    switch self {
    case .build: "hammer.fill"
    case .files: "folder.fill"
    case .workspace: "macwindow"
    case .other: "ellipsis.circle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .build: .orange
    case .files: .blue
    case .workspace: .purple
    case .other: .gray
    }
  }

  static func category(for toolName: String) -> ToolCategory {
    let n = toolName.lowercased()
    if n.contains("build") || n.contains("test") || n.contains("run") ||
      n.contains("preview") || n.contains("snippet") || n.contains("buildlog")
    {
      return .build
    }
    if n.contains("read") || n.contains("write") || n.contains("update") ||
      n.contains("glob") || n.contains("grep") || n.contains("ls") ||
      n.contains("mv") || n.contains("rm") || n.contains("dir") ||
      n.contains("file")
    {
      return .files
    }
    if n.contains("window") || n.contains("issue") || n.contains("navigator") ||
      n.contains("workspace") || n.contains("refresh") || n.contains("documentation") ||
      n.contains("doc")
    {
      return .workspace
    }
    return .other
  }
}

// MARK: - Helpers

func formatUptime(since date: Date) -> String {
  let interval = max(0, Date().timeIntervalSince(date))
  let hours = Int(interval) / 3600
  let minutes = (Int(interval) % 3600) / 60
  let seconds = Int(interval) % 60
  if hours > 0 {
    return String(format: "%dh %02dm", hours, minutes)
  }
  if minutes > 0 {
    return String(format: "%dm %02ds", minutes, seconds)
  }
  return String(format: "%ds", seconds)
}

#if DEBUG
#Preview("Running") {
  ContentView(viewModel: StatusViewModel.previewRunning())
    .frame(width: 960, height: 640)
}

#Preview("Idle") {
  ContentView(viewModel: StatusViewModel.previewIdle())
    .frame(width: 960, height: 640)
}

#Preview("Not installed") {
  ContentView(viewModel: StatusViewModel.previewNotInstalled())
    .frame(width: 960, height: 640)
}
#endif
