import ComposableArchitecture
import SwiftUI
import XcodeMCPTapShared

public struct ContentView: View {
  @Bindable public var store: StoreOf<AppFeature>
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebar
        .navigationSplitViewColumnWidth(
          min: SidebarWidth.primaryMin,
          ideal: SidebarWidth.primaryIdeal,
          max: SidebarWidth.primaryMax,
        )
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: WindowSize.appMinWidth, minHeight: WindowSize.appMinHeight)
    .task { await store.send(.task).finish() }
  }

  private var sidebar: some View {
    List(selection: $store.selection) {
      ForEach(SidebarItem.allCases) { item in
        Label(item.title, systemImage: item.systemImage)
          .badge(badge(for: item))
          .tag(item)
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Xcode MCP Tap")
    .safeAreaInset(edge: .bottom, spacing: 0) {
      sidebarFooter
    }
  }

  private var sidebarFooter: some View {
    SidebarFooter(
      isServiceRunning: store.isServiceRunning,
      isInstalled: store.isInstalled,
    )
  }

  private func badge(for item: SidebarItem) -> Int {
    switch item {
    case .overview: 0
    case .tools: store.tools.tools.count
    case .connections: store.connections.count
    case .settings: 0
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch store.selection {
    case .overview:
      OverviewView(store: store)
    case .tools:
      ToolsView(store: store.scope(state: \.tools, action: \.tools))
    case .connections:
      ConnectionsView(store: store)
    case .settings:
      SettingsView(store: store)
    }
  }
}

public enum SidebarItem: String, Hashable, CaseIterable, Identifiable, Sendable {
  case overview
  case tools
  case connections
  case settings

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .overview: "Overview"
    case .tools: "Tools"
    case .connections: "Connections"
    case .settings: "Settings"
    }
  }

  public var systemImage: String {
    switch self {
    case .overview: "gauge.with.dots.needle.bottom.50percent"
    case .tools: "wrench.and.screwdriver"
    case .connections: "personalhotspot"
    case .settings: "gearshape"
    }
  }
}

/// Pinned strip along the bottom of the sidebar showing a single
/// service-state line. Kept deliberately minimal — anything richer
/// belongs in the Overview pane, not in every sidebar.
public struct SidebarFooter: View {
  public var isServiceRunning: Bool
  public var isInstalled: Bool

  public init(isServiceRunning: Bool, isInstalled: Bool) {
    self.isServiceRunning = isServiceRunning
    self.isInstalled = isInstalled
  }

  public var body: some View {
    HStack(spacing: Spacing.s) {
      StatusDot(running: isServiceRunning)
      Text(text)
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.l)
    .padding(.vertical, Spacing.s)
    .background(.bar)
    .overlay(alignment: .top) {
      Divider()
    }
  }

  private var text: String {
    if isServiceRunning { return "Service running" }
    if isInstalled { return "Service stopped" }
    return "Not installed"
  }
}

/// Compact tri-state dot for the mcpbridge subprocess:
/// yellow = `.booting`, green = `.ready`, red = `.failed`.
/// No pulse — used both inside cards and in the sidebar footer where the
/// service-level `StatusDot` already carries the animation.
public struct BridgeStatusDot: View {
  public var status: BridgeStatus

  public init(status: BridgeStatus) {
    self.status = status
  }

  public var body: some View {
    Circle()
      .fill(color)
      .frame(width: IconSize.miniStatusDotInner, height: IconSize.miniStatusDotInner)
      .shadow(color: color.opacity(SurfaceOpacity.shadow), radius: 2)
  }

  private var color: Color {
    switch status {
    case .booting: Color.yellow
    case .ready: Color.green
    case .failed: Color.red
    }
  }
}

public struct StatusDot: View {
  public var running: Bool
  @State private var pulse = false

  public init(running: Bool) {
    self.running = running
  }

  public var body: some View {
    ZStack {
      if running {
        Circle()
          .stroke(Color.green.opacity(SurfaceOpacity.border), lineWidth: BorderWidth.ring)
          .frame(width: IconSize.statusDotOuter, height: IconSize.statusDotOuter)
          .scaleEffect(pulse ? 2.4 : 1.0)
          .opacity(pulse ? 0 : 0.7)
      }
      Circle()
        .fill(running ? Color.green : Color.red.opacity(SurfaceOpacity.mutedDot))
        .frame(width: IconSize.statusDotInner, height: IconSize.statusDotInner)
        .shadow(
          color: (running ? Color.green : Color.red).opacity(SurfaceOpacity.shadow),
          radius: 3,
        )
    }
    .frame(width: IconSize.statusDotFrame, height: IconSize.statusDotFrame)
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

public enum ToolCategory: String, CaseIterable, Hashable, Identifiable, Sendable {
  case build = "Build & Run"
  case files = "Files"
  case workspace = "Workspace"
  case other = "Other"

  public var id: String { rawValue }

  public var systemImage: String {
    switch self {
    case .build: "hammer.fill"
    case .files: "folder.fill"
    case .workspace: "macwindow"
    case .other: "ellipsis.circle.fill"
    }
  }

  public var tint: Color {
    switch self {
    case .build: .orange
    case .files: .blue
    case .workspace: .purple
    case .other: .gray
    }
  }

  public static func category(for toolName: String) -> ToolCategory {
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

public func formatUptime(interval: TimeInterval) -> String {
  let clamped = max(0, interval)
  let hours = Int(clamped) / 3600
  let minutes = (Int(clamped) % 3600) / 60
  let seconds = Int(clamped) % 60
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
    ContentView(store: Store(initialState: .previewRunning()) { AppFeature() })
      .frame(width: 960, height: 640)
  }

  #Preview("Idle") {
    ContentView(store: Store(initialState: .previewIdle()) { AppFeature() })
      .frame(width: 960, height: 640)
  }

  #Preview("Not installed") {
    ContentView(store: Store(initialState: .previewNotInstalled()) { AppFeature() })
      .frame(width: 960, height: 640)
  }
#endif
