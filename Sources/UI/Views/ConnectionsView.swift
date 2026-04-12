import SwiftUI
import XcodeMCPTapShared

public struct ConnectionsView: View {
  @Bindable public var viewModel: StatusViewModel
  @State private var now: Date

  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  public init(viewModel: StatusViewModel) {
    self.viewModel = viewModel
    self._now = State(initialValue: viewModel.nowProvider())
  }

  public var body: some View {
    Group {
      if viewModel.connections.isEmpty {
        ContentUnavailableView(
          "No active connections",
          systemImage: "personalhotspot.slash"
        )
      } else {
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(viewModel.connections) { connection in
              ConnectionRow(connection: connection, now: now)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .navigationTitle("Connections")
    .onReceive(timer) { now = $0 }
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
  ConnectionsView(viewModel: .previewRunning())
    .frame(width: 640, height: 300)
}

#Preview("Empty") {
  let model = StatusViewModel.previewIdle()
  model.connections = []
  return ConnectionsView(viewModel: model)
    .frame(width: 640, height: 300)
}
#endif
