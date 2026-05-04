import XcodeMCPTapClient
import XcodeMCPTapUI

@main
enum Xcmcptap {
  static func main() {
    let identity = BuildConfig.identity
    switch Subcommand.parse(CommandLine.arguments) {
    case .install:
      ServiceInstaller(identity: identity).install()
    case .uninstall:
      ServiceInstaller(identity: identity).uninstall()
    case .proxy:
      ClientMain.run(identity: identity)
    }
  }
}
