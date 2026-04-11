import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import struct Foundation.Data

public enum MCPProtocol {
  /// MCP protocol version this proxy implements. Must match what the
  /// installed `mcpbridge` expects.
  public static let version = "2025-11-25"

  /// Standard MCP `initialize` params with empty capabilities.
  public static func initializeParams(
    clientName: String,
    clientVersion: String
  ) -> JSONValue {
    .object([
      "protocolVersion": .string(version),
      "capabilities": .object([:]),
      "clientInfo": .object([
        "name": .string(clientName),
        "version": .string(clientVersion),
      ]),
    ])
  }
}

/// Decoded payload of an MCP `initialize` response's `result` field.
public struct InitializeResult: Decodable, Sendable, Equatable {
  public var protocolVersion: String
  public var serverInfo: ServerInfo

  public struct ServerInfo: Decodable, Sendable, Equatable {
    public var name: String
    public var version: String?
  }
}

/// Decoded payload of an MCP `tools/list` response's `result` field.
public struct ListToolsResult: Decodable, Sendable, Equatable {
  public var tools: [Tool]

  public struct Tool: Decodable, Sendable, Equatable {
    public var name: String
    public var description: String?
  }
}

public struct RPCEnvelope: Codable, Sendable, Equatable {
  public var id: JSONValue?
  public var method: String?
  public var rest: [String: JSONValue]

  public init(id: JSONValue? = nil, method: String? = nil, rest: [String: JSONValue] = [:]) {
    self.id = id
    self.method = method
    self.rest = rest
  }

  public init(from decoder: Decoder) throws {
    var all = try [String: JSONValue](from: decoder)
    id = all.removeValue(forKey: "id")
    if let methodValue = all.removeValue(forKey: "method") {
      guard case .string(let m) = methodValue else {
        throw DecodingError.typeMismatch(
          String.self,
          .init(
            codingPath: decoder.codingPath,
            debugDescription: "\"method\" must be a string"
          )
        )
      }
      method = m
    }
    rest = all
  }

  public func encode(to encoder: Encoder) throws {
    var merged = rest
    if let id { merged["id"] = id }
    if let method { merged["method"] = .string(method) }
    try merged.encode(to: encoder)
  }

  /// Decodes the envelope's `result` field as the given `Decodable` type.
  public func decodeResult<T: Decodable>(as type: T.Type) throws -> T {
    guard let raw = rest["result"] else {
      throw RPCDecodingError.missingResult
    }
    let data = try JSONEncoder().encode(raw)
    return try JSONDecoder().decode(T.self, from: data)
  }
}

public enum RPCDecodingError: Error, CustomStringConvertible {
  case missingResult

  public var description: String {
    switch self {
    case .missingResult: "RPCEnvelope has no \"result\" field to decode"
    }
  }
}
