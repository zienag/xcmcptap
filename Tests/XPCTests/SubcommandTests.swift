import Testing
import XcodeMCPTapClient

@Suite struct SubcommandTests {
  @Test func bareInvocationParsesAsProxy() {
    #expect(Subcommand.parse(["xcmcptap"]) == .proxy)
  }

  @Test func emptyArgumentsParseAsProxy() {
    #expect(Subcommand.parse([]) == .proxy)
  }

  @Test func installArgumentParsesAsInstall() {
    #expect(Subcommand.parse(["xcmcptap", "install"]) == .install)
  }

  @Test func uninstallArgumentParsesAsUninstall() {
    #expect(Subcommand.parse(["xcmcptap", "uninstall"]) == .uninstall)
  }

  @Test func unknownArgumentFallsThroughToProxy() {
    // Agents may pass flags we don't recognise; behaviour should fall back to
    // proxying so we don't break existing MCP clients.
    #expect(Subcommand.parse(["xcmcptap", "--verbose"]) == .proxy)
  }

  @Test func installIsCaseSensitive() {
    #expect(Subcommand.parse(["xcmcptap", "Install"]) == .proxy)
  }
}
