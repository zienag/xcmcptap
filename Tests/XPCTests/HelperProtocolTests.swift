import Foundation
import Testing
import XcodeMCPTapShared

@Suite struct HelperProtocolTests {
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  @Test func installSymlinkRoundTrip() throws {
    let request = HelperRequest.installSymlink(sourcePath: "/Applications/Xcode MCP Tap.app/Contents/MacOS/xcmcptap")
    let data = try encoder.encode(request)
    let decoded = try decoder.decode(HelperRequest.self, from: data)
    #expect(decoded == request)
  }

  @Test func removeSymlinkRoundTrip() throws {
    let request = HelperRequest.removeSymlink
    let data = try encoder.encode(request)
    let decoded = try decoder.decode(HelperRequest.self, from: data)
    #expect(decoded == request)
  }

  @Test func statusRoundTrip() throws {
    let request = HelperRequest.status
    let data = try encoder.encode(request)
    let decoded = try decoder.decode(HelperRequest.self, from: data)
    #expect(decoded == request)
  }

  @Test func successResponseRoundTrip() throws {
    let response = HelperResponse.success
    let data = try encoder.encode(response)
    let decoded = try decoder.decode(HelperResponse.self, from: data)
    #expect(decoded == response)
  }

  @Test func failureResponseRoundTrip() throws {
    let response = HelperResponse.failure(reason: "cannot create symlink: permission denied")
    let data = try encoder.encode(response)
    let decoded = try decoder.decode(HelperResponse.self, from: data)
    #expect(decoded == response)
  }

  @Test func helperServiceNameIsDistinct() {
    let identity = Identity(
      serviceName: "alfred.xcmcptap",
      appDisplayName: "Xcode MCP Tap",
      symlinkName: "xcmcptap",
    )
    #expect(identity.helperServiceName != identity.serviceName)
    #expect(identity.helperServiceName != identity.statusServiceName)
    #expect(!identity.helperServiceName.isEmpty)
  }
}
