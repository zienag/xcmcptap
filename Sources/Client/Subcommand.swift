/// Top-level subcommands accepted by the `xcmcptap` CLI.
///
/// Bare invocation (`xcmcptap`) means "act as the MCP proxy" — read JSON-RPC
/// from stdin, forward over XPC, write replies to stdout. Anything else is a
/// one-shot administrative command that exits when it's done.
public enum Subcommand: Equatable, Sendable {
  case proxy
  case install
  case uninstall

  public static func parse(_ arguments: [String]) -> Subcommand {
    guard arguments.count >= 2 else { return .proxy }
    switch arguments[1] {
    case "install": return .install
    case "uninstall": return .uninstall
    default: return .proxy
    }
  }
}
