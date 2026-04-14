import Foundation
import Testing
import XcodeMCPTapHelper
import XcodeMCPTapShared

@Suite(.serialized)
struct HelperHandlerTests {
  let workDir: URL
  let source: URL
  let destination: String

  init() throws {
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("helper-handler-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    source = workDir.appendingPathComponent("bin")
    try Data("bin".utf8).write(to: source)
    destination = workDir.appendingPathComponent("link").path
  }

  private func makeHandler() -> HelperHandler {
    HelperHandler(destination: destination)
  }

  @Test
  func dispatchInstallSymlinkCreatesLink() throws {
    let response = makeHandler().handle(.installSymlink(sourcePath: source.path))
    #expect(response == .success)

    let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: destination)
    #expect(resolved == source.path)
  }

  @Test
  func dispatchRemoveSymlinkRemovesLink() throws {
    _ = makeHandler().handle(.installSymlink(sourcePath: source.path))

    let response = makeHandler().handle(.removeSymlink)
    #expect(response == .success)
    #expect(!FileManager.default.fileExists(atPath: destination))
  }

  @Test
  func dispatchStatusReturnsSuccess() {
    let response = makeHandler().handle(.status)
    #expect(response == .success)
  }

  @Test
  func dispatchUsesInjectedDestinationNotSourcesChoice() throws {
    let alt = workDir.appendingPathComponent("alt-link").path
    let handler = HelperHandler(destination: alt)

    let response = handler.handle(.installSymlink(sourcePath: source.path))
    #expect(response == .success)

    #expect(FileManager.default.fileExists(atPath: alt))
    #expect(!FileManager.default.fileExists(atPath: destination))
  }
}
