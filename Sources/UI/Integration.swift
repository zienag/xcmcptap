public struct Integration: Equatable, Identifiable, Sendable {
  public var id: String
  public var displayName: String
  public var text: String
  public var configPath: String

  public init(id: String, displayName: String, text: String, configPath: String) {
    self.id = id
    self.displayName = displayName
    self.text = text
    self.configPath = configPath
  }
}

public extension Integration {
  static func all(clientPath: String, onSystemPath: Bool = false) -> [Integration] {
    let command = onSystemPath ? "xcmcptap" : clientPath
    return [
      .init(
        id: "claude",
        displayName: "Claude Code",
        text: "claude mcp add --transport stdio xcode -- \(command)",
        configPath: "~/.claude.json",
      ),
      .init(
        id: "codex",
        displayName: "Codex",
        text: "codex mcp add xcode -- \(command)",
        configPath: "~/.codex/config.toml",
      ),
      .init(
        id: "gemini",
        displayName: "Gemini CLI",
        text: "gemini mcp add xcode \(command)",
        configPath: "~/.gemini/settings.json",
      ),
      .init(
        id: "vscode",
        displayName: "VS Code",
        text: #"code --add-mcp '{"name":"xcode","command":"\#(command)"}'"#,
        configPath: "~/Library/Application Support/Code/User/mcp.json",
      ),
      .init(
        id: "cursor",
        displayName: "Cursor",
        text: #"{"mcpServers":{"xcode":{"command":"\#(command)"}}}"#,
        configPath: "~/.cursor/mcp.json",
      ),
      .init(
        id: "windsurf",
        displayName: "Windsurf",
        text: #"{"mcpServers":{"xcode":{"command":"\#(command)"}}}"#,
        configPath: "~/.codeium/windsurf/mcp_config.json",
      ),
    ]
  }
}
