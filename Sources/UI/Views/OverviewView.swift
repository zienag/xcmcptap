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
      VStack(alignment: .leading, spacing: Spacing.m) {
        statusBar
        statsGrid
      }
      .padding(Spacing.l)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle("Overview")
  }

  private var statusBar: some View {
    HStack(spacing: Spacing.s) {
      StatusDot(running: store.isServiceRunning)
      Text(statusText)
        .font(.headline)
      Spacer(minLength: Spacing.s)
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
    .padding(.horizontal, Spacing.l)
    .padding(.vertical, Spacing.m)
    .cardSurface(radius: Radius.large)
  }

  private var statusText: String {
    if store.isServiceRunning { return "Service running" }
    if store.isInstalled { return "Service stopped" }
    return "Service not installed"
  }

  private var statsGrid: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 4),
      spacing: Spacing.s
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
    let content = HStack(alignment: .center, spacing: Spacing.s) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: IconSize.tile, height: IconSize.tile)
        .background(
          tint.opacity(SurfaceOpacity.iconTint),
          in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        )
      VStack(alignment: .leading, spacing: 0) {
        Text(value)
          .font(.system(size: 18, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.primary)
          .minimumScaleFactor(0.7)
          .lineLimit(1)
        Text(label)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      }
      Spacer(minLength: 0)
      if action != nil {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, Spacing.m)
    .padding(.vertical, Spacing.s)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(radius: Radius.large)
    .overlay {
      RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
        .fill(Color.primary.opacity(hovered && action != nil ? SurfaceOpacity.hover : 0))
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
