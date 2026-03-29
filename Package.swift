// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "XcodeMCPProxy",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "XcodeMCPShared", targets: ["XcodeMCPShared"]),
    .executable(name: "xcode-mcp-service", targets: ["xcode-mcp-service"]),
    .executable(name: "xcode-mcp-client", targets: ["xcode-mcp-client"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.4.0"),
  ],
  targets: [
    .target(name: "XcodeMCPShared", path: "Sources/Shared"),
    .executableTarget(
      name: "xcode-mcp-service",
      dependencies: [
        "XcodeMCPShared",
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      path: "Sources/Service"
    ),
    .executableTarget(
      name: "xcode-mcp-client",
      dependencies: ["XcodeMCPShared"],
      path: "Sources/Client"
    ),
    .executableTarget(
      name: "xpc-test-echo-server",
      dependencies: ["XcodeMCPShared"],
      path: "Sources/TestEchoServer"
    ),
    .testTarget(
      name: "XPCTests",
      dependencies: ["XcodeMCPShared"],
      path: "Tests/XPCTests"
    ),
  ]
)
