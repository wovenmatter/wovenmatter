import Foundation

/// A hybrid logical clock value: wall time in milliseconds, a counter for
/// writes within one millisecond, and the machine that wrote. Its text form
/// sorts in clock order, so SQL and Swift compare stamps as plain strings.
struct Stamp: Equatable {
  var time: Int64
  var count: Int64
  var machine: String

  var text: String {
    Self.hex(time, width: 12) + "." + Self.hex(count, width: 6) + "." + machine
  }

  init(time: Int64, count: Int64, machine: String) {
    self.time = time
    self.count = count
    self.machine = machine
  }

  init?(text: String) {
    let parts = text.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, let time = Int64(parts[0], radix: 16), let count = Int64(parts[1], radix: 16) else { return nil }
    self.init(time: time, count: count, machine: String(parts[2]))
  }

  /// The machine part of a stamp's text.
  static func machine(of text: String) -> String? {
    Stamp(text: text)?.machine
  }

  private static func hex(_ value: Int64, width: Int) -> String {
    let digits = String(value, radix: 16)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }
}

/// The library's clock. Each local write gets a stamp later than every stamp
/// this library has written or received, even when wall clocks disagree.
struct HybridClock {
  let machine: String
  private(set) var last: Stamp?

  init(machine: String, last: String) {
    self.machine = machine
    self.last = Stamp(text: last)
  }

  mutating func tick(now: Date = Date()) -> String {
    let wall = Int64(now.timeIntervalSince1970 * 1000)
    let next: Stamp
    if let last, last.time >= wall {
      next = Stamp(time: last.time, count: last.count + 1, machine: machine)
    } else {
      next = Stamp(time: wall, count: 0, machine: machine)
    }
    last = next
    return next.text
  }

  /// Moves the clock past a stamp received from another machine.
  mutating func observe(_ text: String) {
    guard let stamp = Stamp(text: text) else { return }
    if last.map({ $0.text < text }) ?? true {
      last = Stamp(time: stamp.time, count: stamp.count, machine: machine)
    }
  }
}
