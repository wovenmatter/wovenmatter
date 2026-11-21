// swift-tools-version: 6.2

import PackageDescription

// The wire types every client and server speaks. No dependencies, so the UI
// can link it without reaching the library or the server.
let package = Package(
  name: "WovenProtocol",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "WovenProtocol", targets: ["WovenProtocol"])
  ],
  targets: [
    .target(
      name: "WovenProtocol",
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
    )
  ]
)
