import struct Foundation.Data
import class Foundation.JSONDecoder

public struct RPCMessage: Sendable {
  public var parsed: Parsed
  public var raw: Data

  public struct Parsed: Codable, Sendable {
    public var id: Int?
    public var method: String?
  }

  public init?(_ raw: Data) {
    guard let parsed = try? JSONDecoder().decode(Parsed.self, from: raw) else { return nil }
    self.parsed = parsed
    self.raw = raw
  }

  public init?(_ string: String) {
    guard let data = string.data(using: .utf8) else { return nil }
    self.init(data)
  }
}
