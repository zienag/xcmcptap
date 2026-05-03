import class Foundation.ProcessInfo
import XcodeMCPTapHelper
import XcodeMCPTapShared

// Test-only SPM executable wrapper. Production uses the Xcode-native
// `xcmcptap-helper` tool target shipped inside the .app bundle, which
// receives identity from the generated `BuildConfig.swift`.
//
// `HelperEndToEndTests` boots this binary as a user-level LaunchAgent
// and overrides everything via env vars (`HELPER_MACH_SERVICE`,
// `HELPER_DESTINATION`, `HELPER_ALLOW_ANY_PEER=1`). The identity below
// is just enough to satisfy `HelperMain.run(identity:)`; with the env
// overrides in place its values are unused at runtime.
let env = ProcessInfo.processInfo.environment
let identity = Identity(
  serviceName: env["IDENTITY_SERVICE_NAME"] ?? "alfred.xcmcptap.test",
  appDisplayName: "XcodeMCPTap Test",
  symlinkName: env["IDENTITY_SYMLINK_NAME"] ?? "xcmcptap-test",
)
HelperMain.run(identity: identity)
