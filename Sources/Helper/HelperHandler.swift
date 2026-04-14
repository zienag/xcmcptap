import XcodeMCPTapShared

public struct HelperHandler: Sendable {
  public var destination: String

  public init(destination: String) {
    self.destination = destination
  }

  public func handle(_ request: HelperRequest) -> HelperResponse {
    switch request {
    case let .installSymlink(sourcePath):
      SymlinkOperations.install(source: sourcePath, destination: destination)
    case .removeSymlink:
      SymlinkOperations.remove(destination: destination)
    case .status:
      .success
    }
  }
}
