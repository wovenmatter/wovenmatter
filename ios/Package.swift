// swift-tools-version: 6.2
import PackageDescription

// The iPhone and iPad app's packages. `WovenDevice` is the in-app host: the
// server's portable core over the device's library, with Quick Chat. It is the
// only target here that reaches the library or the core; the UI talks to it
// over the protocol. Depending on `server/` brings that package's graph into
// resolution, but the core links none of it (see docs/DEPENDENCIES.md).
let package = Package(
  name: "WovenMatterMobile",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "PiDurableRuntime", targets: ["PiDurableRuntime"]),
    .library(name: "MobileInference", targets: ["MobileInference"]),
    .library(name: "WovenDevice", targets: ["WovenDevice"]),
  ],
  dependencies: [
    .package(path: "../protocol"),
    .package(path: "../library"),
    .package(path: "../server"),
  ],
  targets: [
    .target(name: "PiDurableRuntime", resources: [.process("Resources")], linkerSettings: [.linkedFramework("JavaScriptCore")]),
    .testTarget(name: "PiDurableRuntimeTests", dependencies: ["PiDurableRuntime", "MobileInference"]),
    .target(name: "MobileInference"),
    .testTarget(name: "MobileInferenceTests", dependencies: ["MobileInference"]),
    .target(
      name: "WovenDevice",
      dependencies: [
        "PiDurableRuntime",
        "MobileInference",
        .product(name: "WovenProtocol", package: "protocol"),
        .product(name: "WovenLibrary", package: "library"),
        .product(name: "WovenServerCore", package: "server"),
      ],
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
    ),
    .testTarget(
      name: "WovenDeviceTests",
      dependencies: [
        "WovenDevice",
        "PiDurableRuntime",
        "MobileInference",
        .product(name: "WovenProtocol", package: "protocol"),
      ]
    ),
  ]
)
