import struct Foundation.FileAttributeKey
import struct Foundation.FileAttributeType
import class Foundation.FileManager
import XcodeMCPTapShared

public enum SymlinkOperations {
  /// Creates a symlink at `destination` pointing to `source`. If `destination`
  /// already exists and is a symlink, it's replaced (idempotent). If it's a
  /// regular file or directory, the call fails.
  public static func install(source: String, destination: String) -> HelperResponse {
    let fm = FileManager.default

    if let existing = try? fm.attributesOfItem(atPath: destination) {
      if existing[.type] as? FileAttributeType == .typeSymbolicLink {
        do {
          try fm.removeItem(atPath: destination)
        } catch {
          return .failure(reason: "removing old symlink: \(error.localizedDescription)")
        }
      } else {
        return .failure(reason: "refusing to overwrite non-symlink at \(destination)")
      }
    }

    do {
      try fm.createSymbolicLink(atPath: destination, withDestinationPath: source)
      return .success
    } catch {
      return .failure(reason: "creating symlink: \(error.localizedDescription)")
    }
  }

  /// Removes the symlink at `destination`. Returns success if the destination
  /// is a symlink (deletes it) or doesn't exist (no-op). Fails if the path
  /// exists but isn't a symlink.
  public static func remove(destination: String) -> HelperResponse {
    let fm = FileManager.default

    guard let attrs = try? fm.attributesOfItem(atPath: destination) else {
      return .success
    }

    guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else {
      return .failure(reason: "refusing to remove non-symlink at \(destination)")
    }

    do {
      try fm.removeItem(atPath: destination)
      return .success
    } catch {
      return .failure(reason: "removing symlink: \(error.localizedDescription)")
    }
  }
}
