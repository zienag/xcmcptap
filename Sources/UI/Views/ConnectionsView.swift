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
          systemImage: "personalhotspot.slash"
        )
      } else {
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(store.connections) { connection in
              ConnectionRow(connection: connection, now: store.now)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
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
    HStack(spacing: 12) {
      Image(systemName: activityIsRecent ? "dot.radiowaves.left.and.right" : "personalhotspot")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(activityIsRecent ? .green : .secondary)
        .frame(width: 22, height: 22)
        .background(
          (activityIsRecent ? Color.green : Color.secondary).opacity(0.15),
          in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )

      Text("PID \(connection.bridgePID)")
        .font(.system(.callout, design: .monospaced))
        .frame(width: 110, alignment: .leading)

      Text(formatUptime(interval: now.timeIntervalSince(connection.connectedAt)))
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .frame(width: 70, alignment: .leading)

      Text("last \(lastActivityText)")
        .font(.caption)
        .foregroundStyle(activityIsRecent ? Color.green : Color.secondary)
        .monospacedDigit()
        .frame(width: 70, alignment: .leading)

      Spacer(minLength: 0)

      Text("\(connection.messagesRouted)")
        .font(.system(.callout, design: .rounded).weight(.semibold))
        .monospacedDigit()
      Text("msg")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
    }
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
