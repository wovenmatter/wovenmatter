import Foundation
import Testing
@testable import WovenMatterClient
@testable import WovenMatterDashboardStore

struct GatewayProjectionLocationTests {
  @Test("tool locations preserve first occurrences, trimming, and the depth boundary")
  func locationEquivalence() {
    var deep: GatewayJSONValue = .object(["path": .string("hidden")])
    for _ in 0..<7 { deep = .array([deep]) }
    var lastVisibleDepth: GatewayJSONValue = .object(["path": .string("at-boundary")])
    for _ in 0..<6 { lastVisibleDepth = .array([lastVisibleDepth]) }
    let input: GatewayJSONValue = .array([
      .object(["path": .string(" first ")]),
      .object(["file_path": .string("first")]),
      .object(["nested": .array([.object(["FILE": .string("second")])])]),
      .object(["path": .string("  ")]),
      deep,
      lastVisibleDepth,
    ])
    #expect(projectedLocations(input) == ["first", "second", "at-boundary"])
  }

  @Test("large location input keeps the same first fifty unique paths")
  func boundedLocationEquivalence() {
    let input = GatewayJSONValue.array((0..<10_000).map {
      .object(["path": .string("file-\($0 / 2)")])
    })
    #expect(projectedLocations(input) == (0..<50).map { "file-\($0)" })
  }

  private func projectedLocations(_ input: GatewayJSONValue) -> [String] {
    let event = OpenClawGatewayEvent(name: "agent", payload: .object([
      "stream": .string("tool"),
      "data": .object(["name": .string("read"), "args": input]),
    ]), sequence: 1)
    return OpenClawGatewayEventProjection.project(event)?.activity?.locations.map(\.path) ?? []
  }

}
