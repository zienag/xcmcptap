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
        "\(integration.id) should contain full client path when not on PATH"
      )
      #expect(
        !integration.text.contains("-- xcmcptap"),
        "\(integration.id) should not use bare 'xcmcptap' argument when off PATH"
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
        "\(integration.id) should not contain user-specific path when on PATH"
      )
      #expect(
        integration.text.contains("xcmcptap"),
        "\(integration.id) should still mention xcmcptap"
      )
    }
  }
}
