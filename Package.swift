// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "XcodeMCPTap",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "XcodeMCPTapShared", targets: ["XcodeMCPTapShared"]),
    .executable(name: "xcmcptapd", targets: ["xcmcptapd"]),
    .executable(name: "xcmcptap", targets: ["xcmcptap"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.4.0"),
  ],
  targets: [
    .target(name: "XcodeMCPTapShared", path: "Sources/Shared"),
    .target(
      name: "XcodeMCPTapServiceCore",
      dependencies: [
        "XcodeMCPTapShared",
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      path: "Sources/ServiceCore"
    ),
    .executableTarget(
      name: "xcmcptapd",
      dependencies: [
        "XcodeMCPTapServiceCore",
        "XcodeMCPTapShared",
      ],
      path: "Sources/Service"
    ),
    .executableTarget(
      name: "xcmcptap",
      dependencies: ["XcodeMCPTapShared"],
      path: "Sources/Client"
    ),
    .executableTarget(
      name: "xpc-test-echo-server",
      dependencies: ["XcodeMCPTapShared"],
      path: "Sources/TestEchoServer"
    ),
    .testTarget(
      name: "XPCTests",
      dependencies: [
        "XcodeMCPTapServiceCore",
        "XcodeMCPTapShared",
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      path: "Tests/XPCTests"
    ),
  ]
)
