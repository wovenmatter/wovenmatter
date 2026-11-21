// swift-tools-version: 6.2

import PackageDescription

// Schema, the writer, reads and sync. Depends on the protocol only; nothing
// here can reach the server or the UI.
let package = Package(
  name: "WovenLibrary",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "WovenLibrary", targets: ["WovenLibrary"])
  ],
  dependencies: [
    .package(path: "../protocol"),
    // Linux-only replacement for CryptoKit; see docs/DEPENDENCIES.md.
    .package(url: "https://github.com/apple/swift-crypto.git", "5.1.2"..<"1000.0.0")
  ],
  targets: [
    // Linux links the system SQLite; Apple platforms use the SDK module.
    .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"])]),
    .target(
      name: "WovenLibrary",
      dependencies: [
        .product(name: "WovenProtocol", package: "protocol"),
        .target(name: "CSQLite", condition: .when(platforms: [.linux])),
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
      ],
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")],
      linkerSettings: [.linkedLibrary("sqlite3", .when(platforms: [.macOS, .iOS]))]
    )
  ]
)
