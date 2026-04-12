import AppKit
import ComposableArchitecture
import SwiftUI
import XcodeMCPTapShared

public struct SettingsView: View {
  @Bindable public var store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
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
      isPresented: $store.settings.showingUninstallConfirm,
      titleVisibility: .visible
    ) {
      Button("Uninstall", role: .destructive) {
        store.send(.settings(.uninstallConfirmed))
      }
      Button("Cancel", role: .cancel) {
        store.send(.settings(.uninstallCancelled))
      }
    } message: {
      Text("Removes the launch agent and xcmcptap symlink.")
    }
  }

  private var configCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionLabel("MCP config command")
      HStack(spacing: 8) {
        Text(store.mcpConfigCommand)
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
          store.send(.settings(.copyTapped))
        } label: {
          let copied = store.settings.copied
          Label(
            copied ? "Copied" : "Copy",
            systemImage: copied ? "checkmark" : "doc.on.doc"
          )
          .frame(width: 62)
        }
        .buttonStyle(.bordered)
        .tint(store.settings.copied ? .green : .accentColor)
        .animation(.easeInOut(duration: 0.15), value: store.settings.copied)
      }
    }
  }

  private var pathsCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionLabel("Paths")
      VStack(spacing: 0) {
        PathRow(label: "Client", path: store.clientPath)
        Divider()
        PathRow(label: "Launch agent", path: store.plistPath)
        Divider()
        PathRow(label: "Log", path: store.logPath)
      }
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
      }
    }
  }

  private var actionsRow: some View {
    HStack(spacing: 8) {
      if store.isInstalled {
        Button("Reinstall") { store.send(.settings(.installTapped)) }
        Button("Uninstall", role: .destructive) { store.send(.settings(.uninstallTapped)) }
      } else {
        Button("Install service") { store.send(.settings(.installTapped)) }
          .buttonStyle(.borderedProminent)
      }
      Spacer()
    }
    .controlSize(.regular)
  }
}

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
  SettingsView(store: Store(initialState: .previewRunning()) { AppFeature() })
    .frame(width: 640, height: 320)
}

#Preview("Not installed") {
  SettingsView(store: Store(initialState: .previewNotInstalled()) { AppFeature() })
    .frame(width: 640, height: 320)
}
#endif
