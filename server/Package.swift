// swift-tools-version: 6.2

import PackageDescription

// The background server. Depends on the library and the protocol. The Mac
// app links `WovenServerKit` only at its server entry point.
let package = Package(
  name: "WovenServer",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "WovenServerKit", targets: ["WovenServerKit"]),
    .executable(name: "woven-server", targets: ["woven-server"]),
    .executable(name: "woven-probe", targets: ["woven-probe"])
  ],
  dependencies: [
    .package(path: "../protocol"),
    .package(path: "../library"),
    // The WebSocket server and client, on macOS and Linux alike.
    .package(url: "https://github.com/apple/swift-nio.git", "2.105.2"..<"1000.0.0"),
    // Linux-only replacement for CryptoKit, for sealing; see docs/DEPENDENCIES.md.
    .package(url: "https://github.com/apple/swift-crypto.git", "5.2.0"..<"1000.0.0")
  ],
  targets: [
    .target(
      name: "WovenServerKit",
      dependencies: [
        .product(name: "WovenProtocol", package: "protocol"),
        .product(name: "WovenLibrary", package: "library"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
      ],
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
    ),
    .executableTarget(
      name: "woven-server",
      dependencies: ["WovenServerKit"],
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
    ),
    // A terminal client for checking a running server by hand.
    .executableTarget(
      name: "woven-probe",
      dependencies: ["WovenServerKit", .product(name: "WovenProtocol", package: "protocol")],
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
    ),
    // A scripted ACP agent the tests run as a real child process.
    .executableTarget(
      name: "fake-acp-agent",
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
    ),
    // Sync rules, at the level of the library alone.
    .testTarget(
      name: "LibrarySyncTests",
      dependencies: [
        .product(name: "WovenProtocol", package: "protocol"),
        .product(name: "WovenLibrary", package: "library")
      ]
    ),
    // Sessions and server-to-server sync, through real servers and sockets.
    .testTarget(
      name: "ServerTests",
      dependencies: [
        "WovenServerKit",
        "fake-acp-agent",
        .product(name: "WovenProtocol", package: "protocol"),
        .product(name: "WovenLibrary", package: "library"),
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
      ]
    )
  ]
)
