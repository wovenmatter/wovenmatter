// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WovenMatterMobile",
  platforms: [.iOS(.v18), .macOS(.v14)],
  products: [
    .library(name: "CompanionClient", targets: ["CompanionClient"]),
    .library(name: "PiDurableRuntime", targets: ["PiDurableRuntime"]),
    .library(name: "CompanionInference", targets: ["CompanionInference"]),
  ],
  dependencies: [.package(path: "../shared")],
  targets: [
    .target(name: "CompanionClient", dependencies: [.product(name: "WovenMatterCompanion", package: "shared")]),
    .testTarget(name: "CompanionClientTests", dependencies: ["CompanionClient"]),
    .target(name: "PiDurableRuntime", resources: [.process("Resources")], linkerSettings: [.linkedFramework("JavaScriptCore")]),
    .testTarget(name: "PiDurableRuntimeTests", dependencies: ["PiDurableRuntime", "CompanionInference"]),
    .target(name: "CompanionInference", resources: [.process("Resources")]),
    .testTarget(name: "CompanionInferenceTests", dependencies: ["CompanionInference"]),
  ]
)
