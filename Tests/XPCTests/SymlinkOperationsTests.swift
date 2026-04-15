import Foundation
import OSLog
import Testing
import XcodeMCPTapHelper
import XcodeMCPTapShared

@Suite(.serialized)
struct SymlinkOperationsTests {
  let workDir: URL
  let source: URL

  init() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("symlink-ops-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    workDir = tmp

    source = tmp.appendingPathComponent("source-binary")
    try Data("mock binary".utf8).write(to: source)
  }

  @Test
  func installCreatesSymlinkPointingToSource() throws {
    let dest = workDir.appendingPathComponent("link").path

    let response = SymlinkOperations.install(source: source.path, destination: dest)
    #expect(response == .success)

    let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: dest)
    #expect(resolved == source.path)
  }

  @Test
  func installIsIdempotentAndOverwritesPreviousSymlink() throws {
    let dest = workDir.appendingPathComponent("link").path
    let otherSource = workDir.appendingPathComponent("other-source")
    try Data("other".utf8).write(to: otherSource)

    _ = SymlinkOperations.install(source: otherSource.path, destination: dest)
    let response = SymlinkOperations.install(source: source.path, destination: dest)

    #expect(response == .success)
    let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: dest)
    #expect(resolved == source.path)
  }

  @Test
  func installFailsWhenParentDirectoryMissing() {
    let dest = workDir.appendingPathComponent("missing-dir/link").path

    let response = SymlinkOperations.install(source: source.path, destination: dest)

    guard case .failure = response else {
      Issue.record("expected failure, got \(response)")
      return
    }
  }

  @Test
  func removeDeletesSymlink() throws {
    let dest = workDir.appendingPathComponent("link").path
    _ = SymlinkOperations.install(source: source.path, destination: dest)

    let response = SymlinkOperations.remove(destination: dest)
    #expect(response == .success)
    #expect(!FileManager.default.fileExists(atPath: dest))
  }

  @Test
  func removeIsIdempotentWhenDestinationAbsent() {
    let dest = workDir.appendingPathComponent("never-existed").path

    let response = SymlinkOperations.remove(destination: dest)
    #expect(response == .success)
  }

  @Test
  func removeRefusesToDeleteRegularFile() throws {
    let dest = workDir.appendingPathComponent("regular-file").path
    try Data("not a symlink".utf8).write(to: URL(fileURLWithPath: dest))

    let response = SymlinkOperations.remove(destination: dest)

    guard case .failure = response else {
      Issue.record("expected failure for non-symlink, got \(response)")
      return
    }
    #expect(FileManager.default.fileExists(atPath: dest))
  }

  @Test
  func installEmitsLogUnderHelperSubsystem() async throws {
    let cutoff = Date()
    let dest = workDir.appendingPathComponent("link").path
    _ = SymlinkOperations.install(source: source.path, destination: dest)

    try await Task.sleep(for: .milliseconds(50))

    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let entries = try store.getEntries(at: store.position(date: cutoff))
      .compactMap { $0 as? OSLogEntryLog }
      .filter { $0.subsystem == MCPTap.helperServiceName && $0.category == "symlink" }

    #expect(!entries.isEmpty, "Expected a symlink-category log entry; got \(entries.map(\.composedMessage))")
  }
}
