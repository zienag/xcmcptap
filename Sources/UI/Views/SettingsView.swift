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
      VStack(alignment: .leading, spacing: Spacing.l) {
        configCard
        pathsCard
        actionsRow
      }
      .padding(Spacing.l)
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
    VStack(alignment: .leading, spacing: Spacing.s) {
      SectionLabel("MCP config command")
      HStack(spacing: Spacing.s) {
        Text(store.mcpConfigCommand)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.middle)
          .padding(.horizontal, Spacing.s)
          .padding(.vertical, Spacing.s)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
          )
          .cardBorder(radius: Radius.small)

        Button {
          store.send(.settings(.copyTapped))
        } label: {
          let copied = store.settings.copied
          Label(
            copied ? "Copied" : "Copy",
            systemImage: copied ? "checkmark" : "doc.on.doc"
          )
          .fixedSize()
        }
        .buttonStyle(.bordered)
        .tint(store.settings.copied ? .green : .accentColor)
        .animation(.easeInOut(duration: 0.15), value: store.settings.copied)
      }
    }
  }

  private var pathsCard: some View {
    VStack(alignment: .leading, spacing: Spacing.s) {
      SectionLabel("Paths")
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
        pathRow(label: "Client", path: store.clientPath)
        Divider().gridCellUnsizedAxes(.horizontal)
        pathRow(label: "Launch agent", path: store.plistPath)
        Divider().gridCellUnsizedAxes(.horizontal)
        pathRow(label: "Log", path: store.logPath)
      }
      .padding(Spacing.m)
      .cardSurface(radius: Radius.medium)
    }
  }

  @ViewBuilder
  private func pathRow(label: String, path: String) -> some View {
    let exists = FileManager.default.fileExists(atPath: path)
    GridRow(alignment: .firstTextBaseline) {
      Text(label)
        .foregroundStyle(.secondary)
        .font(.caption)
        .lineLimit(1)
        .gridColumnAlignment(.leading)
      Text(path)
        .font(.system(.caption, design: .monospaced))
        .truncationMode(.middle)
        .lineLimit(1)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if exists {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
          Image(systemName: "arrow.up.right.square")
            .font(.caption)
            .foregroundStyle(.secondary)
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
  }

  private var actionsRow: some View {
    HStack(spacing: Spacing.s) {
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
