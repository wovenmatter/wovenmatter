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

  /// The largest counter that fits its width.
  static let maxCount: Int64 = 0xFFFFFF

  init?(text: String) {
    let parts = text.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 12, parts[1].count == 6, let time = Int64(parts[0], radix: 16), let count = Int64(parts[1], radix: 16) else { return nil }
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
/// this library has written or received, unless that stamp is further ahead
/// of this machine's wall clock than `maxLead`: a
/// machine whose clock runs fast cannot drag the others' clocks with it. A
/// write that replaces a row is always stamped later than that row.
struct HybridClock {
  /// How far a received stamp may move this clock ahead of the wall clock.
  static let maxLead: Int64 = 5 * 60 * 1000

  let machine: String
  private(set) var last: Stamp?

  init(machine: String, last: String) {
    self.machine = machine
    self.last = Stamp(text: last)
  }

  /// A stamp for a local write. With `over`, the stamp of the row being
  /// replaced, it is also later than that stamp, however far ahead it is,
  /// so the write always replaces that row on every machine. The clock
  /// itself follows such a stamp no further than `maxLead`, so one far-future
  /// row does not carry every later write with it.
  mutating func tick(over replaced: String? = nil, now: Date = Date()) -> String {
    let wall = Self.millis(now)
    let next: Stamp
    if let last, last.time >= wall {
      next = Self.after(last, machine: machine)
    } else {
      next = Stamp(time: wall, count: 0, machine: machine)
    }
    last = next
    guard let floor = replaced.flatMap(Stamp.init(text:)), (next.time, next.count) <= (floor.time, floor.count) else {
      return next.text
    }
    let above = Self.after(floor, machine: machine)
    observe(above.text, now: now)
    return above.text
  }

  /// The next stamp after `stamp`; the counter carries into the time part
  /// rather than outgrow its width.
  private static func after(_ stamp: Stamp, machine: String) -> Stamp {
    stamp.count < Stamp.maxCount
      ? Stamp(time: stamp.time, count: stamp.count + 1, machine: machine)
      : Stamp(time: stamp.time + 1, count: 0, machine: machine)
  }

  /// Moves the clock past a stamp received from another machine, but never
  /// more than `maxLead` ahead of the wall clock.
  mutating func observe(_ text: String, now: Date = Date()) {
    guard var stamp = Stamp(text: text) else { return }
    let limit = Self.millis(now) + Self.maxLead
    if stamp.time > limit { stamp = Stamp(time: limit, count: 0, machine: machine) }
    if last.map({ ($0.time, $0.count) < (stamp.time, stamp.count) }) ?? true {
      last = Stamp(time: stamp.time, count: stamp.count, machine: machine)
    }
  }

  private static func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
}
