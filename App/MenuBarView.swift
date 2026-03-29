import SwiftUI
import XcodeMCPShared

struct MenuBarView: View {
  @Bindable var viewModel: StatusViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      headerSection
      Divider()
      if viewModel.isServiceRunning {
        connectionsSection
        Divider()
        healthSection
        Divider()
      }
      actionsSection
    }
    .frame(width: 320)
  }

  // MARK: - Sections

  private var headerSection: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(viewModel.isServiceRunning ? .green : .red)
        .frame(width: 8, height: 8)
      Text(viewModel.isServiceRunning ? "Service Running" : "Service Stopped")
        .font(.headline)
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var connectionsSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Connections")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 8)

      if viewModel.connections.isEmpty {
        Text("No active connections")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
      } else {
        ForEach(viewModel.connections) { connection in
          ConnectionRow(connection: connection)
        }
      }
    }
    .padding(.bottom, 8)
  }

  private var healthSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let health = viewModel.health {
        HStack {
          Text("Uptime")
            .foregroundStyle(.secondary)
          Spacer()
          Text(formatUptime(since: health.startedAt))
            .monospacedDigit()
        }
        .font(.caption)

        HStack {
          Text("Total served")
            .foregroundStyle(.secondary)
          Spacer()
          Text("\(health.totalConnectionsServed)")
            .monospacedDigit()
        }
        .font(.caption)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  private var actionsSection: some View {
    VStack(spacing: 4) {
      if !viewModel.isInstalled {
        Button("Install Service") {
          viewModel.install()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      } else {
        Button("Reinstall Service") {
          viewModel.install()
        }
        .controlSize(.small)
      }

      if viewModel.isInstalled {
        Button("Copy Claude Config Command") {
          viewModel.copyConfigCommand()
        }
        .controlSize(.small)

        Button("Uninstall Service") {
          viewModel.uninstall()
        }
        .controlSize(.small)
        .foregroundStyle(.red)
      }

      Divider()

      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  // MARK: - Helpers

  private func formatUptime(since date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    let hours = Int(interval) / 3600
    let minutes = (Int(interval) % 3600) / 60
    let seconds = Int(interval) % 60
    if hours > 0 {
      return String(format: "%dh %02dm", hours, minutes)
    }
    return String(format: "%dm %02ds", minutes, seconds)
  }
}

struct ConnectionRow: View {
  var connection: ConnectionInfo

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(.green)
        .frame(width: 6, height: 6)

      VStack(alignment: .leading, spacing: 2) {
        Text("PID \(connection.bridgePID)")
          .font(.caption)
          .fontWeight(.medium)
        Text("Connected \(connection.connectedAt, style: .relative) ago")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Text("\(connection.messagesRouted) msgs")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 4)
  }
}
