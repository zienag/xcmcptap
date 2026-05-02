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
        integrationsCard
        pathsCard
        actionsRow
        if !store.appVersion.isEmpty {
          Text("Version \(store.appVersion)")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(Spacing.l)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle("Settings")
    .confirmationDialog(
      "Uninstall the service?",
      isPresented: $store.settings.showingUninstallConfirm,
      titleVisibility: .visible,
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

  private var integrationsCard: some View {
    VStack(alignment: .leading, spacing: Spacing.s) {
      SectionLabel("Integrations")
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
        let integrations = store.integrations
        ForEach(Array(integrations.enumerated()), id: \.element.id) { index, integration in
          integrationRow(integration)
          if index != integrations.count - 1 {
            Divider().gridCellUnsizedAxes(.horizontal)
          }
        }
      }
      .padding(Spacing.m)
      .cardSurface(radius: Radius.medium)
    }
  }

  @ViewBuilder
  private func integrationRow(_ integration: Integration) -> some View {
    let copied = store.settings.copiedIntegrationID == integration.id
    GridRow(alignment: .firstTextBaseline) {
      Text(integration.displayName)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .gridColumnAlignment(.leading)
      Text(integration.text)
        .font(.system(.caption, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        store.send(
          .settings(
            .revealAndCopyTapped(
              id: integration.id,
              command: integration.text,
              configPath: integration.configPath,
            ),
          ),
        )
      } label: {
        Label(
          copied ? "Copied" : "Reveal",
          systemImage: copied ? "checkmark" : "arrow.up.right.square",
        )
        .fixedSize()
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .tint(copied ? .green : .accentColor)
      .help("Reveal \(integration.configPath) in Finder and copy the snippet to the clipboard")
      .animation(.easeInOut(duration: 0.15), value: copied)
    }
  }

  private var pathsCard: some View {
    VStack(alignment: .leading, spacing: Spacing.s) {
      SectionLabel("Paths")
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
        pathRow(label: "Client", path: store.clientPath)
        Divider().gridCellUnsizedAxes(.horizontal)
        pathRow(label: "Launch agent", path: store.plistPath)
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
        systemPathButton
      } else {
        Button("Install service") { store.send(.settings(.installTapped)) }
          .buttonStyle(.borderedProminent)
      }
      Spacer()
    }
    .controlSize(.regular)
  }

  @ViewBuilder
  private var systemPathButton: some View {
    if store.isOnSystemPath {
      Button("Remove from /usr/local/bin") {
        store.send(.settings(.uninstallSystemPathTapped))
      }
    } else {
      Button("Install to /usr/local/bin") {
        store.send(.settings(.installSystemPathTapped))
      }
    }
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
      .frame(width: 640, height: 520)
  }

  #Preview("Not installed") {
    SettingsView(store: Store(initialState: .previewNotInstalled()) { AppFeature() })
      .frame(width: 640, height: 520)
  }
#endif
