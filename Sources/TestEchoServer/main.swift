import XPC
import XcodeMCPTapShared

let serviceName = "alfred.xcmcptap.test-echo"

let listener = try XPCListener(service: serviceName) { request in
  let (decision, _) = request.accept(
    incomingMessageHandler: { (message: MCPLine) -> (any Encodable)? in
      MCPLine("echo:" + message.content)
    },
    cancellationHandler: nil
  )
  return decision
}

print("[echo-server] Listening on \(serviceName)")
fflush(stdout)
dispatchMain()
