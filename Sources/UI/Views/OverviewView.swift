import ComposableArchitecture
import SwiftUI
import XcodeMCPTapShared

public struct OverviewView: View {
  @Bindable public var store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        statusBar
        statsGrid
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle("Overview")
  }

  private var statusBar: some View {
    HStack(spacing: 10) {
      StatusDot(running: store.isServiceRunning)
      Text(statusText)
        .font(.headline)
      Spacer(minLength: 8)
      if store.isServiceRunning, let uptime = store.uptimeText {
        Label(uptime, systemImage: "clock")
          .labelStyle(.titleAndIcon)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else if !store.isInstalled {
        Button("Install") { store.send(.installTapped) }
          .controlSize(.regular)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
    }
  }

  private var statusText: String {
    if store.isServiceRunning { return "Service running" }
    if store.isInstalled { return "Service stopped" }
    return "Service not installed"
  }

  private var statsGrid: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
      spacing: 10
    ) {
      StatTile(
        label: "Tools",
        value: "\(store.tools.tools.count)",
        icon: "wrench.and.screwdriver.fill",
        tint: .orange
      ) { store.selection = .tools }

      StatTile(
        label: "Active",
        value: "\(store.connections.count)",
        icon: "personalhotspot",
        tint: .green
      ) { store.selection = .connections }

      StatTile(
        label: "Served",
        value: "\(store.health?.totalConnectionsServed ?? 0)",
        icon: "tray.full.fill",
        tint: .blue
      )

      StatTile(
        label: "Messages",
        value: "\(store.totalMessagesRouted)",
        icon: "arrow.left.arrow.right",
        tint: .purple
      )
    }
  }
}

public struct StatTile: View {
  public var label: String
  public var value: String
  public var icon: String
  public var tint: Color
  public var action: (() -> Void)?
  @State private var hovered = false

  public init(
    label: String,
    value: String,
    icon: String,
    tint: Color,
    action: (() -> Void)? = nil
  ) {
    self.label = label
    self.value = value
    self.icon = icon
    self.tint = tint
    self.action = action
  }

  public var body: some View {
    let content = HStack(alignment: .center, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 26, height: 26)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      VStack(alignment: .leading, spacing: 0) {
        Text(value)
          .font(.system(size: 18, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.primary)
        Text(label)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if action != nil {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.primary.opacity(hovered && action != nil ? 0.04 : 0))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
    }

    if let action {
      Button(action: action) { content }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    } else {
      content
    }
  }
}

#if DEBUG
#Preview("Running") {
  OverviewView(store: Store(initialState: .previewRunning()) { AppFeature() })
    .frame(width: 640, height: 200)
}

#Preview("Not installed") {
  OverviewView(store: Store(initialState: .previewNotInstalled()) { AppFeature() })
    .frame(width: 640, height: 200)
}
#endif
