import struct Foundation.FileAttributeKey
import struct Foundation.FileAttributeType
import class Foundation.FileManager
import os
import XcodeMCPTapShared

public struct SymlinkOperations: Sendable {
  private let log: Logger

  public init(serviceName: String) {
    self.log = Logger(subsystem: serviceName, category: "symlink")
  }

  /// Creates a symlink at `destination` pointing to `source`. If `destination`
  /// already exists and is a symlink, it's replaced (idempotent). If it's a
  /// regular file or directory, the call fails.
  public func install(source: String, destination: String) -> HelperResponse {
    let fm = FileManager.default

    if let existing = try? fm.attributesOfItem(atPath: destination) {
      if existing[.type] as? FileAttributeType == .typeSymbolicLink {
        do {
          try fm.removeItem(atPath: destination)
        } catch {
          let reason = "removing old symlink: \(error.localizedDescription)"
          log.error("install failed: \(reason, privacy: .public)")
          return .failure(reason: reason)
        }
      } else {
        let reason = "refusing to overwrite non-symlink at \(destination)"
        log.error("install failed: \(reason, privacy: .public)")
        return .failure(reason: reason)
      }
    }

    do {
      try fm.createSymbolicLink(atPath: destination, withDestinationPath: source)
      log.notice("installed symlink \(destination, privacy: .public) → \(source, privacy: .public)")
      return .success
    } catch {
      let reason = "creating symlink: \(error.localizedDescription)"
      log.error("install failed: \(reason, privacy: .public)")
      return .failure(reason: reason)
    }
  }

  /// Removes the symlink at `destination`. Returns success if the destination
  /// is a symlink (deletes it) or doesn't exist (no-op). Fails if the path
  /// exists but isn't a symlink.
  public func remove(destination: String) -> HelperResponse {
    let fm = FileManager.default

    guard let attrs = try? fm.attributesOfItem(atPath: destination) else {
      log.notice("remove no-op: \(destination, privacy: .public) does not exist")
      return .success
    }

    guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else {
      let reason = "refusing to remove non-symlink at \(destination)"
      log.error("remove failed: \(reason, privacy: .public)")
      return .failure(reason: reason)
    }

    do {
      try fm.removeItem(atPath: destination)
      log.notice("removed symlink \(destination, privacy: .public)")
      return .success
    } catch {
      let reason = "removing symlink: \(error.localizedDescription)"
      log.error("remove failed: \(reason, privacy: .public)")
      return .failure(reason: reason)
    }
  }
}
