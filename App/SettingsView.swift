import AppKit
import SwiftUI
import XcodeMCPTapShared

struct SettingsView: View {
  @Bindable var viewModel: StatusViewModel
  @State private var copied = false
  @State private var copyResetTask: Task<Void, Never>?
  @State private var showingUninstallConfirm = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        configCard
        pathsCard
        actionsRow
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle("Settings")
    .confirmationDialog(
      "Uninstall the service?",
      isPresented: $showingUninstallConfirm,
      titleVisibility: .visible
    ) {
      Button("Uninstall", role: .destructive) { viewModel.uninstall() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Removes the launch agent and xcmcptap symlink.")
    }
  }

  // MARK: - Config card

  private var configCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionLabel("MCP config command")
      HStack(spacing: 8) {
        Text(viewModel.mcpConfigCommand)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.middle)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
          }

        Button {
          viewModel.copyConfigCommand()
          copied = true
          copyResetTask?.cancel()
          copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { copied = false }
          }
        } label: {
          Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            .frame(width: 62)
        }
        .buttonStyle(.bordered)
        .tint(copied ? .green : .accentColor)
        .animation(.easeInOut(duration: 0.15), value: copied)
      }
    }
  }

  // MARK: - Paths card

  private var pathsCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionLabel("Paths")
      VStack(spacing: 0) {
        PathRow(label: "Client", path: viewModel.clientPath)
        Divider()
        PathRow(label: "Launch agent", path: viewModel.plistPath)
        Divider()
        PathRow(label: "Log", path: viewModel.logPath)
      }
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
      }
    }
  }

  // MARK: - Actions row

  private var actionsRow: some View {
    HStack(spacing: 8) {
      if viewModel.isInstalled {
        Button("Reinstall") { viewModel.install() }
        Button("Uninstall", role: .destructive) { showingUninstallConfirm = true }
      } else {
        Button("Install service") { viewModel.install() }
          .buttonStyle(.borderedProminent)
      }
      Spacer()
    }
    .controlSize(.regular)
  }
}

// MARK: - Section label

private struct SectionLabel: View {
  var text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text.uppercased())
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .tracking(0.4)
  }
}

// MARK: - Path row

private struct PathRow: View {
  var label: String
  var path: String
  @State private var hovered = false

  private var fileExists: Bool {
    FileManager.default.fileExists(atPath: path)
  }

  var body: some View {
    HStack(spacing: 10) {
      Text(label)
        .foregroundStyle(.secondary)
        .font(.caption)
        .frame(width: 88, alignment: .leading)
      Text(path)
        .font(.system(.caption, design: .monospaced))
        .truncationMode(.middle)
        .lineLimit(1)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if fileExists {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
          Image(systemName: "arrow.up.right.square")
            .font(.caption)
            .foregroundStyle(hovered ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Reveal in Finder")
      } else {
        Image(systemName: "questionmark.circle")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .help("File does not exist")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .background(hovered ? Color.primary.opacity(0.04) : .clear)
    .onHover { hovered = $0 }
  }
}

#if DEBUG
#Preview("Installed") {
  SettingsView(viewModel: .previewRunning())
    .frame(width: 640, height: 320)
}

#Preview("Not installed") {
  SettingsView(viewModel: .previewNotInstalled())
    .frame(width: 640, height: 320)
}
#endif
