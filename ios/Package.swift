// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "WovenMatterMobile",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "LibraryClient", targets: ["LibraryClient"]),
    .library(name: "PiDurableRuntime", targets: ["PiDurableRuntime"]),
    .library(name: "MobileInference", targets: ["MobileInference"]),
    .library(name: "EmbeddedExecution", targets: ["EmbeddedExecution"]),
  ],
  dependencies: [.package(path: "../shared")],
  targets: [
    .target(name: "LibraryClient", dependencies: [.product(name: "WovenMatterShared", package: "shared")]),
    .testTarget(name: "LibraryClientTests", dependencies: ["LibraryClient"]),
    .target(name: "PiDurableRuntime", resources: [.process("Resources")], linkerSettings: [.linkedFramework("JavaScriptCore")]),
    .testTarget(name: "PiDurableRuntimeTests", dependencies: ["PiDurableRuntime", "MobileInference"]),
    .target(name: "EmbeddedExecution", resources: [.copy("Resources")], linkerSettings: [.linkedFramework("WebKit")]),
    .testTarget(name: "EmbeddedExecutionTests", dependencies: ["EmbeddedExecution"]),
    .target(name: "MobileInference"),
    .testTarget(name: "MobileInferenceTests", dependencies: ["MobileInference"]),
  ]
)
