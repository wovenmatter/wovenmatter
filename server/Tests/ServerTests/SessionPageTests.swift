import Foundation
import Testing
import WovenProtocol

/// A client that paged back keeps those items when a newer snapshot arrives,
/// and never holds a gap.
@Test func newerPageJoinsHeldItems() {
  func items(_ sequences: ClosedRange<Int>, _ text: String = "held") -> [SessionItem] {
    sequences.map { SessionItem(id: "item-\($0)", sessionID: "s", sequence: $0, createdAt: Date(timeIntervalSince1970: 0),
                                content: .assistantMessage(text: "\(text) \($0)")) }
  }
  let held = items(1...300)
  // The snapshot wins for what it covers, the older pages stay, with no duplicates.
  let joined = held.joined(withNewer: items(101...310, "snapshot"))
  #expect(joined.map(\.sequence) == Array(1...310))
  #expect(joined[100].content == .assistantMessage(text: "snapshot 101"))
  #expect(joined[99].content == .assistantMessage(text: "held 100"))
  // A snapshot that does not reach the held items replaces them.
  #expect(held.joined(withNewer: items(400...600)).map(\.sequence) == Array(400...600))
}
