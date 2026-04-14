public struct Integration: Equatable, Identifiable, Sendable {
  public var id: String
  public var displayName: String
  public var text: String

  public init(id: String, displayName: String, text: String) {
    self.id = id
    self.displayName = displayName
    self.text = text
  }
}

extension Integration {
  public static func all(clientPath: String, onSystemPath: Bool = false) -> [Integration] {
    let command = onSystemPath ? "xcmcptap" : clientPath
    return [
      .init(
        id: "claude",
        displayName: "Claude Code",
        text: "claude mcp add --transport stdio xcode -- \(command)"
      ),
      .init(
        id: "codex",
        displayName: "Codex",
        text: "codex mcp add xcode -- \(command)"
      ),
      .init(
        id: "gemini",
        displayName: "Gemini CLI",
        text: "gemini mcp add xcode \(command)"
      ),
      .init(
        id: "vscode",
        displayName: "VS Code",
        text: #"code --add-mcp '{"name":"xcode","command":"\#(command)"}'"#
      ),
      .init(
        id: "cursor",
        displayName: "Cursor",
        text: #"{"mcpServers":{"xcode":{"command":"\#(command)"}}}"#
      ),
      .init(
        id: "windsurf",
        displayName: "Windsurf",
        text: #"{"mcpServers":{"xcode":{"command":"\#(command)"}}}"#
      ),
    ]
  }
}
