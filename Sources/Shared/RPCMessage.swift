import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

public struct RPCMessage: Sendable {
  public var parsed: Parsed
  public var raw: Data

  public struct Parsed: Codable, Sendable {
    public var id: RPCId?
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

/// JSON-RPC id: can be Int, String, or null.
public enum RPCId: Codable, Sendable, Equatable {
  case int(Int)
  case string(String)

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let v = try? container.decode(Int.self) {
      self = .int(v)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .int(let v): try container.encode(v)
    case .string(let v): try container.encode(v)
    }
  }

  /// The underlying value for use in untyped dictionaries.
  public var jsonValue: Any {
    switch self {
    case .int(let v): v
    case .string(let v): v
    }
  }
}
