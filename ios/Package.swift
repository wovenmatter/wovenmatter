// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "WovenMatterMobile",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "PiDurableRuntime", targets: ["PiDurableRuntime"]),
    .library(name: "MobileInference", targets: ["MobileInference"]),
  ],
  targets: [
    .target(name: "PiDurableRuntime", resources: [.process("Resources")], linkerSettings: [.linkedFramework("JavaScriptCore")]),
    .testTarget(name: "PiDurableRuntimeTests", dependencies: ["PiDurableRuntime", "MobileInference"]),
    .target(name: "MobileInference"),
    .testTarget(name: "MobileInferenceTests", dependencies: ["MobileInference"]),
  ]
)
