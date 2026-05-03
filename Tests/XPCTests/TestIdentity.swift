import XcodeMCPTapShared

/// Identity values used across XPCTests that need to wire up routers,
/// connections, helpers, or installers. Must NEVER overlap with the
/// production Mach service names (`alfred.xcmcptap[.debug]*`) — when
/// these tests stand up real launchd jobs (HelperEndToEndTests etc.)
/// they advertise these names in the Mach name namespace.
let testServiceName = "alfred.xcmcptap.test"
let testHelperServiceName = "alfred.xcmcptap.test.helper"
let testIdentity = Identity(
  serviceName: testServiceName,
  appDisplayName: "XcodeMCPTap Test",
  symlinkName: "xcmcptap-test",
)
