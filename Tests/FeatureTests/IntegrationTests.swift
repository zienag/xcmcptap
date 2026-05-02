import Testing
import XcodeMCPTapUI

struct IntegrationTests {
  @Test
  func offSystemPathUsesFullClientPath() {
    let clientPath = "/Users/alice/.local/bin/xcmcptap"
    let integrations = Integration.all(clientPath: clientPath, onSystemPath: false)

    for integration in integrations {
      #expect(
        integration.text.contains(clientPath),
        "\(integration.id) should contain full client path when not on PATH",
      )
      #expect(
        !integration.text.contains("-- xcmcptap"),
        "\(integration.id) should not use bare 'xcmcptap' argument when off PATH",
      )
    }
  }

  @Test
  func onSystemPathUsesBareCommand() {
    let clientPath = "/Users/alice/.local/bin/xcmcptap"
    let integrations = Integration.all(clientPath: clientPath, onSystemPath: true)

    for integration in integrations {
      #expect(
        !integration.text.contains(clientPath),
        "\(integration.id) should not contain user-specific path when on PATH",
      )
      #expect(
        integration.text.contains("xcmcptap"),
        "\(integration.id) should still mention xcmcptap",
      )
    }
  }

  @Test
  func eachIntegrationKnowsItsConfigPath() {
    let integrations = Integration.all(clientPath: "/tmp/xcmcptap", onSystemPath: false)
    let byID = Dictionary(uniqueKeysWithValues: integrations.map { ($0.id, $0.configPath) })

    #expect(byID["claude"] == "~/.claude.json")
    #expect(byID["codex"] == "~/.codex/config.toml")
    #expect(byID["gemini"] == "~/.gemini/settings.json")
    #expect(byID["vscode"] == "~/Library/Application Support/Code/User/mcp.json")
    #expect(byID["cursor"] == "~/.cursor/mcp.json")
    #expect(byID["windsurf"] == "~/.codeium/windsurf/mcp_config.json")
  }
}
