import XcodeMCPTapShared

public struct HelperHandler: Sendable {
  public var destination: String
  private let symlinks: SymlinkOperations

  public init(destination: String, serviceName: String) {
    self.destination = destination
    self.symlinks = SymlinkOperations(serviceName: serviceName)
  }

  public func handle(_ request: HelperRequest) -> HelperResponse {
    switch request {
    case let .installSymlink(sourcePath):
      symlinks.install(source: sourcePath, destination: destination)
    case .removeSymlink:
      symlinks.remove(destination: destination)
    case .status:
      .success
    }
  }
}
