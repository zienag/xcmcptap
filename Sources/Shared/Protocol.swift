import struct Foundation.Date
import struct Foundation.UUID

public enum MCPTap {
  public static let serviceName = "alfred.xcmcptap"
  public static let statusServiceName = "alfred.xcmcptap.status"
  public static let helperServiceName = "alfred.xcmcptap.helper"
}

// MARK: - Privileged Helper Protocol

public enum HelperRequest: Codable, Equatable, Sendable {
  case installSymlink(sourcePath: String)
  case removeSymlink
  case status
}

public enum HelperResponse: Codable, Equatable, Sendable {
  case success
  case failure(reason: String)
}

public struct MCPLine: Codable, Sendable {
  public var content: String
  /// PID of the client process that sent this message. Only populated on
  /// client→service direction — the service leaves this `nil` when it
  /// sends bridge output back to the client. Optional on the wire so old
  /// messages that predate the field still decode.
  public var clientPID: Int32?

  public init(_ content: String, clientPID: Int32? = nil) {
    self.content = content
    self.clientPID = clientPID
  }
}

// MARK: - Status Protocol

public struct StatusRequest: Codable, Sendable {
  public init() {}
}

public struct StatusResponse: Codable, Equatable, Sendable {
  public var connections: [ConnectionInfo]
  public var health: ServiceHealth
  public var tools: [ToolInfo]
  public var bridge: BridgeStatus

  public init(
    connections: [ConnectionInfo],
    health: ServiceHealth,
    tools: [ToolInfo] = [],
    bridge: BridgeStatus = .booting,
  ) {
    self.connections = connections
    self.health = health
    self.tools = tools
    self.bridge = bridge
  }
}

/// Lifecycle state of the underlying `xcrun mcpbridge` subprocess.
/// Broadcast to UI clients so they can show the state of the tool pipeline
/// independently of whether the XcodeMCPTap service itself is alive.
public enum BridgeStatus: Codable, Equatable, Sendable {
  /// Subprocess is starting or running its MCP initialize handshake.
  case booting
  /// Init handshake finished; the bridge is ready to accept tool calls.
  case ready
  /// The current bridge subprocess crashed or exited. `reason` carries
  /// the last stderr line (e.g. `FATAL_NO_XCODE`) or a transport error.
  case failed(reason: String)
}

public struct ConnectionInfo: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var connectedAt: Date
  public var messagesRouted: Int
  public var lastActivityAt: Date
  /// PID of the client agent process (Claude Code, Cursor, Codex, etc.).
  /// Populated from the first `MCPLine` the client sends; `0` until then.
  /// The mcpbridge PID is shared across every connection and therefore
  /// not useful to surface per-row — the client PID is what differentiates
  /// simultaneously-connected agents.
  public var clientPID: Int32

  public init(
    id: UUID,
    connectedAt: Date,
    messagesRouted: Int,
    lastActivityAt: Date,
    clientPID: Int32,
  ) {
    self.id = id
    self.connectedAt = connectedAt
    self.messagesRouted = messagesRouted
    self.lastActivityAt = lastActivityAt
    self.clientPID = clientPID
  }
}

public struct ServiceHealth: Codable, Equatable, Sendable {
  public var startedAt: Date
  public var totalConnectionsServed: Int
  public var activeConnectionCount: Int

  public init(startedAt: Date, totalConnectionsServed: Int, activeConnectionCount: Int) {
    self.startedAt = startedAt
    self.totalConnectionsServed = totalConnectionsServed
    self.activeConnectionCount = activeConnectionCount
  }
}

public struct ToolInfo: Codable, Equatable, Sendable, Identifiable {
  public var name: String
  public var description: String

  public var id: String { name }

  public init(name: String, description: String) {
    self.name = name
    self.description = description
  }
}

public enum StatusEvent: Codable, Equatable, Sendable {
  case connectionOpened(ConnectionInfo)
  case connectionClosed(ConnectionInfo)
  case bridgeStateChanged(BridgeStatus)
}
