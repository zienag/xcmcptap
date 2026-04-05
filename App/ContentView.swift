import SwiftUI
import XcodeMCPTapShared

struct ContentView: View {
  @Bindable var viewModel: StatusViewModel

  var body: some View {
    VStack(spacing: 0) {
      headerBar
      Divider()
      if viewModel.isServiceRunning {
        List {
          toolsSection
          connectionsSection
          healthSection
        }
      } else {
        ContentUnavailableView(
          "Service Not Running",
          systemImage: "xmark.circle",
          description: Text("Install the service to get started.")
        )
      }
      Divider()
      actionsBar
    }
  }

  // MARK: - Header

  private var headerBar: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(viewModel.isServiceRunning ? .green : .red)
        .frame(width: 10, height: 10)
      Text(viewModel.isServiceRunning ? "Service Running" : "Service Stopped")
        .font(.headline)
      Spacer()
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }

  // MARK: - Tools

  private var toolsSection: some View {
    Section("Tools") {
      if viewModel.tools.isEmpty {
        Text("No tools discovered")
          .foregroundStyle(.secondary)
      } else {
        ForEach(viewModel.tools) { tool in
          VStack(alignment: .leading, spacing: 2) {
            Text(tool.name)
              .fontWeight(.medium)
              .fontDesign(.monospaced)
            if !tool.description.isEmpty {
              Text(tool.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  // MARK: - Connections

  private var connectionsSection: some View {
    Section("Connections") {
      if viewModel.connections.isEmpty {
        Text("No active connections")
          .foregroundStyle(.secondary)
      } else {
        ForEach(viewModel.connections) { connection in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("PID \(connection.bridgePID)")
                .fontWeight(.medium)
              Text("Connected \(connection.connectedAt, style: .relative) ago")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(connection.messagesRouted) msgs")
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
      }
    }
  }

  // MARK: - Health

  private var healthSection: some View {
    Section("Health") {
      if let health = viewModel.health {
        LabeledContent("Uptime", value: formatUptime(since: health.startedAt))
          .monospacedDigit()
        LabeledContent("Total served", value: "\(health.totalConnectionsServed)")
          .monospacedDigit()
      }
    }
  }

  // MARK: - Actions

  private var actionsBar: some View {
    HStack(spacing: 12) {
      if viewModel.isInstalled {
        Button("Reinstall") {
          viewModel.install()
        }
        Button("Copy Config") {
          viewModel.copyConfigCommand()
        }
        Button("Uninstall") {
          viewModel.uninstall()
        }
        .foregroundStyle(.red)
      } else {
        Button("Install Service") {
          viewModel.install()
        }
        .buttonStyle(.borderedProminent)
      }
      Spacer()
    }
    .controlSize(.small)
    .padding(.horizontal)
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
