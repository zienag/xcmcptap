import XcodeMCPTapShared

public struct HelperHandler: Sendable {
  public var destination: String

  public init(destination: String) {
    self.destination = destination
  }

  public func handle(_ request: HelperRequest) -> HelperResponse {
    switch request {
    case .installSymlink(let sourcePath):
      return SymlinkOperations.install(source: sourcePath, destination: destination)
    case .removeSymlink:
      return SymlinkOperations.remove(destination: destination)
    case .status:
      return .success
    }
  }
}
