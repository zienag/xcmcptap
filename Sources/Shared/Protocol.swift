import struct Foundation.Date
import struct Foundation.UUID

public enum MCPTap {
  public static let serviceName = "alfred.xcmcptap"
  public static let statusServiceName = "alfred.xcmcptap.status"
}

public struct MCPLine: Codable, Sendable {
  public var content: String

  public init(_ content: String) {
    self.content = content
  }
}

// MARK: - Status Protocol

public struct StatusRequest: Codable, Sendable {
  public init() {}
}

public struct StatusResponse: Codable, Sendable {
  public var connections: [ConnectionInfo]
  public var health: ServiceHealth
  public var tools: [ToolInfo]

  public init(connections: [ConnectionInfo], health: ServiceHealth, tools: [ToolInfo] = []) {
    self.connections = connections
    self.health = health
    self.tools = tools
  }
}

public struct ConnectionInfo: Codable, Sendable, Identifiable {
  public var id: UUID
  public var connectedAt: Date
  public var messagesRouted: Int
  public var lastActivityAt: Date
  public var bridgePID: Int32

  public init(id: UUID, connectedAt: Date, messagesRouted: Int, lastActivityAt: Date, bridgePID: Int32) {
    self.id = id
    self.connectedAt = connectedAt
    self.messagesRouted = messagesRouted
    self.lastActivityAt = lastActivityAt
    self.bridgePID = bridgePID
  }
}

public struct ServiceHealth: Codable, Sendable {
  public var startedAt: Date
  public var totalConnectionsServed: Int
  public var activeConnectionCount: Int

  public init(startedAt: Date, totalConnectionsServed: Int, activeConnectionCount: Int) {
    self.startedAt = startedAt
    self.totalConnectionsServed = totalConnectionsServed
    self.activeConnectionCount = activeConnectionCount
  }
}

public struct ToolInfo: Codable, Sendable, Identifiable {
  public var name: String
  public var description: String

  public var id: String { name }

  public init(name: String, description: String) {
    self.name = name
    self.description = description
  }
}

public struct StatusEvent: Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case connectionOpened
    case connectionClosed
  }

  public var kind: Kind
  public var connection: ConnectionInfo

  public init(kind: Kind, connection: ConnectionInfo) {
    self.kind = kind
    self.connection = connection
  }
}
