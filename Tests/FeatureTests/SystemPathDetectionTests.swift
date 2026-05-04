import Testing
import XcodeMCPTapUI

@Suite struct SystemPathDetectionTests {
  @Test func detectsAppleSiliconBrewPrefix() {
    let detected = ServiceInstaller.isReachableViaPath(symlinkName: "xcmcptap") { path in
      path == "/opt/homebrew/bin/xcmcptap"
    }
    #expect(detected)
  }

  @Test func detectsIntelBrewOrSystemPrefix() {
    let detected = ServiceInstaller.isReachableViaPath(symlinkName: "xcmcptap") { path in
      path == "/usr/local/bin/xcmcptap"
    }
    #expect(detected)
  }

  @Test func returnsFalseWhenNothingExists() {
    let detected = ServiceInstaller.isReachableViaPath(symlinkName: "xcmcptap") { _ in false }
    #expect(!detected)
  }

  @Test func usesSymlinkNameToBuildCandidates() {
    var queried: [String] = []
    _ = ServiceInstaller.isReachableViaPath(symlinkName: "xcmcptap-dev") { path in
      queried.append(path)
      return false
    }
    #expect(queried.contains("/opt/homebrew/bin/xcmcptap-dev"))
    #expect(queried.contains("/usr/local/bin/xcmcptap-dev"))
  }
}
