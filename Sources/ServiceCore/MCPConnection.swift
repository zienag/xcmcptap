import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import class Foundation.NSDecimalNumber
import protocol Foundation.DataProtocol
import struct Foundation.Data
import struct Foundation.Decimal
import XcodeMCPTapShared

/// Thin JSON-RPC layer on top of a byte transport.
///
/// Handles request/response correlation for messages this connection
/// originates (via `request`), while leaving everything else opaque on the
/// `passthrough` stream. Reserved IDs for internal requests are negative;
/// clients are expected to use positive IDs.
public actor MCPConnection {
  private let bridge: BridgeProcess
  private var pending: [Int: CheckedContinuation<RPCEnvelope, any Error>] = [:]
  private var nextReservedID = -1
  private let passthroughContinuation: AsyncStream<[UInt8]>.Continuation

  public nonisolated let passthrough: AsyncStream<[UInt8]>

  public init(bridge: BridgeProcess) {
    self.bridge = bridge
    (self.passthrough, self.passthroughContinuation) = AsyncStream.makeStream()
  }

  public func start() {
    bridge.start()
    Task { await self.readLoop() }
  }

  /// Sends a request with a reserved internal ID and awaits the matching response.
  public func request(method: String, params: JSONValue) async throws -> RPCEnvelope {
    let id = reserveID()
    let envelope = RPCEnvelope(
      id: .number(Decimal(id)),
      method: method,
      rest: [
        "jsonrpc": "2.0",
        "params": params,
      ]
    )
    let data = try JSONEncoder().encode(envelope)
    return try await withCheckedThrowingContinuation { cont in
      pending[id] = cont
      Task {
        do {
          try await bridge.write(data)
        } catch {
          if let c = pending.removeValue(forKey: id) {
            c.resume(throwing: error)
          }
        }
      }
    }
  }

  /// Sends a notification (no response expected).
  public func notify(method: String, params: JSONValue? = nil) async throws {
    var rest: [String: JSONValue] = ["jsonrpc": "2.0"]
    if let params { rest["params"] = params }
    let envelope = RPCEnvelope(method: method, rest: rest)
    let data = try JSONEncoder().encode(envelope)
    try await bridge.write(data)
  }

  /// Forwards raw bytes from a client through to the transport unchanged.
  public func forward(_ bytes: sending some DataProtocol) async throws {
    try await bridge.write(bytes)
  }

  // MARK: - Private

  private func reserveID() -> Int {
    let id = nextReservedID
    nextReservedID -= 1
    return id
  }

  private func readLoop() async {
    for await line in bridge.messages {
      // Try to extract the id; if it matches a pending reserved request,
      // resume it. Everything else goes out on passthrough untouched.
      if let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: Data(line)),
         case .number(let n)? = envelope.id {
        let id = NSDecimalNumber(decimal: n).intValue
        if id < 0, let cont = pending.removeValue(forKey: id) {
          cont.resume(returning: envelope)
          continue
        }
      }
      passthroughContinuation.yield(line)
    }
    passthroughContinuation.finish()
    for (_, cont) in pending {
      cont.resume(throwing: MCPConnectionError.transportClosed)
    }
    pending.removeAll()
  }
}

public enum MCPConnectionError: Error, CustomStringConvertible {
  case transportClosed

  public var description: String {
    switch self {
    case .transportClosed: "MCPConnection transport closed before response arrived"
    }
  }
}
