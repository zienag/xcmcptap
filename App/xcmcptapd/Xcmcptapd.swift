import XcodeMCPTapService

@main
enum Xcmcptapd {
  static func main() {
    ServiceMain.run(identity: BuildConfig.identity)
  }
}
