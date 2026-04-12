// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "XcodeMCPTap",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "XcodeMCPTapShared", targets: ["XcodeMCPTapShared"]),
    .library(name: "XcodeMCPTapClient", targets: ["XcodeMCPTapClient"]),
    .library(name: "XcodeMCPTapService", targets: ["XcodeMCPTapService"]),
    .library(name: "XcodeMCPTapUI", targets: ["XcodeMCPTapUI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.4.0"),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
  ],
  targets: [
    .target(name: "XcodeMCPTapShared", path: "Sources/Shared"),
    .target(
      name: "XcodeMCPTapClient",
      dependencies: ["XcodeMCPTapShared"],
      path: "Sources/Client"
    ),
    .target(
      name: "XcodeMCPTapService",
      dependencies: [
        "XcodeMCPTapShared",
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      path: "Sources/Service"
    ),
    .target(
      name: "XcodeMCPTapUI",
      dependencies: ["XcodeMCPTapShared"],
      path: "Sources/UI"
    ),
    .executableTarget(
      name: "xpc-test-echo-server",
      dependencies: ["XcodeMCPTapShared"],
      path: "Sources/TestEchoServer"
    ),
    .testTarget(
      name: "XPCTests",
      dependencies: [
        "XcodeMCPTapService",
        "XcodeMCPTapShared",
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      path: "Tests/XPCTests"
    ),
    .testTarget(
      name: "UISnapshotTests",
      dependencies: [
        "XcodeMCPTapUI",
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
      ],
      path: "Tests/UISnapshotTests"
    ),
  ]
)
