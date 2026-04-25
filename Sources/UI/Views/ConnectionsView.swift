import ComposableArchitecture
import SwiftUI
import XcodeMCPTapShared

public struct ConnectionsView: View {
  public var store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
    Group {
      if store.connections.isEmpty {
        ContentUnavailableView(
          "No active connections",
          systemImage: "personalhotspot.slash",
        )
      } else {
        ScrollView {
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: 0) {
            ForEach(Array(store.connections.enumerated()), id: \.element.id) { index, connection in
              if index > 0 {
                Divider().gridCellUnsizedAxes(.horizontal)
              }
              ConnectionRow(connection: connection, now: store.now)
            }
          }
          .padding(.vertical, Spacing.s)
          .padding(.horizontal, Spacing.m)
          .frame(maxWidth: .infinity, alignment: .leading)
          .cardSurface(radius: Radius.medium)
          .padding(Spacing.l)
        }
      }
    }
    .navigationTitle("Connections")
  }
}

private struct ConnectionRow: View {
  var connection: ConnectionInfo
  var now: Date

  private var activityIsRecent: Bool {
    now.timeIntervalSince(connection.lastActivityAt) < 5
  }

  private var lastActivityText: String {
    let interval = now.timeIntervalSince(connection.lastActivityAt)
    if interval < 2 { return "now" }
    if interval < 60 { return "\(Int(interval))s" }
    if interval < 3600 { return "\(Int(interval / 60))m" }
    return "\(Int(interval / 3600))h"
  }

  var body: some View {
    GridRow(alignment: .center) {
      Image(systemName: activityIsRecent ? "dot.radiowaves.left.and.right" : "personalhotspot")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(activityIsRecent ? .green : .secondary)
        .frame(width: IconSize.listBadge, height: IconSize.listBadge)
        .background(
          (activityIsRecent ? Color.green : Color.secondary).opacity(SurfaceOpacity.iconTint),
          in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous),
        )

      Text(verbatim: "PID \(connection.clientPID)")
        .font(.system(.callout, design: .monospaced))
        .lineLimit(1)
        .gridColumnAlignment(.leading)

      Text(formatUptime(interval: now.timeIntervalSince(connection.connectedAt)))
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .gridColumnAlignment(.leading)

      Text("last \(lastActivityText)")
        .font(.caption)
        .foregroundStyle(activityIsRecent ? Color.green : Color.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .gridColumnAlignment(.leading)

      HStack(spacing: Spacing.xs) {
        Spacer(minLength: 0)
        Text(verbatim: "\(connection.messagesRouted)")
          .font(.system(.callout, design: .rounded).weight(.semibold))
          .monospacedDigit()
        Text("msg")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .gridColumnAlignment(.trailing)
    }
    .padding(.vertical, Spacing.s)
  }
}

#if DEBUG
  #Preview("Active") {
    ConnectionsView(store: Store(initialState: .previewRunning()) { AppFeature() })
      .frame(width: 640, height: 300)
  }

  #Preview("Empty") {
    var state = AppFeature.State.previewIdle()
    state.connections = []
    return ConnectionsView(store: Store(initialState: state) { AppFeature() })
      .frame(width: 640, height: 300)
  }
#endif
