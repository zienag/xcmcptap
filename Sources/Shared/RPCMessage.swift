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
}
