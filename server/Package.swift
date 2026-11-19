// swift-tools-version: 6.2

import PackageDescription

// The background server. Depends on the library and the protocol. The Mac
// app links `WovenServerKit` only at its server entry point.
let package = Package(
  name: "WovenServer",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "WovenServerKit", targets: ["WovenServerKit"]),
    .executable(name: "woven-server", targets: ["woven-server"])
  ],
  dependencies: [
    .package(path: "../protocol"),
    .package(path: "../library"),
    // The WebSocket server and client, on macOS and Linux alike.
    .package(url: "https://github.com/apple/swift-nio.git", "2.105.0"..<"1000.0.0")
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
        .product(name: "NIOWebSocket", package: "swift-nio")
      ],
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
    ),
    .executableTarget(
      name: "woven-server",
      dependencies: ["WovenServerKit"],
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
        .product(name: "WovenProtocol", package: "protocol"),
        .product(name: "WovenLibrary", package: "library")
      ]
    )
  ]
)
