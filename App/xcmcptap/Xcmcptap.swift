import XcodeMCPTapClient

@main
enum Xcmcptap {
  static func main() {
    ClientMain.run(identity: BuildConfig.identity)
  }
}
