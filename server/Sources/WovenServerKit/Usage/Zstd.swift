import Foundation

/// A Zstandard decoder (RFC 8878), for the histories Codex keeps compressed.
/// It reads frames without dictionaries, which is what Codex writes, and
/// does not check the optional content checksum. It decodes as a stream: a
/// block at a time, keeping only the window a frame may refer back into, so
/// a file of any size is read in bounded memory. Any file may have been
/// written by anyone, so every malformed input throws `Failure`: nothing in
/// here may trap, loop without end or grow without bound.
enum Zstd {
  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = "Zstandard: " + description }
  }

  /// The format's largest block, before and after decompression.
  static let maximumBlock = 128 * 1024
  /// The largest window a frame may ask for: what the reference decoder
  /// accepts by default, far above the few MiB Codex's frames use.
  static let maximumWindow = 128 * 1024 * 1024

  /// The whole of `data`, decompressed.
  static func decompress(_ data: Data) throws -> Data {
    var decoder = Decoder(data)
    var output: [UInt8] = []
    while let bytes = try decoder.next() { output += bytes }
    return Data(output)
  }

  /// Decodes one input in order, one block per call.
  struct Decoder {
    private let input: Data
    private let maximumWindow: Int
    private var position = 0
    private var frame: Frame?

    init(_ input: Data, maximumWindow: Int = Zstd.maximumWindow) {
      self.input = input
      self.maximumWindow = maximumWindow
    }

    /// The bytes of the next block, or nil once the input is used up.
    mutating func next() throws -> [UInt8]? {
      try input.withUnsafeBytes { raw in
        let input = raw.bindMemory(to: UInt8.self)
        while true {
          if var current = frame {
            let (bytes, next, finished) = try current.nextBlock(input, at: position)
            position = next
            frame = finished ? nil : current
            return bytes
          }
          guard position < input.count else { return nil }
          guard input.count - position >= 4 else { throw Failure("truncated frame") }
          let magic = UInt32(input[position]) | UInt32(input[position + 1]) << 8 | UInt32(input[position + 2]) << 16
            | UInt32(input[position + 3]) << 24
          position += 4
          if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
            guard input.count - position >= 4 else { throw Failure("truncated skippable frame") }
            let size = Int(input[position]) | Int(input[position + 1]) << 8 | Int(input[position + 2]) << 16
              | Int(input[position + 3]) << 24
            guard input.count - position - 4 >= size else { throw Failure("truncated skippable frame") }
            position += 4 + size
            continue
          }
          guard magic == 0xFD2F_B528 else { throw Failure("not a Zstandard frame") }
          var started = Frame()
          position = try started.header(input, at: position, maximumWindow: maximumWindow)
          frame = started
        }
      }
    }
  }

  // MARK: Frames and blocks

  private struct Frame {
    var repeats = [1, 4, 8]
    var huffman: HuffmanTable?
    var literalLengths: FSETable?
    var offsets: FSETable?
    var matchLengths: FSETable?
    /// How far back a match may reach.
    var windowSize = 0
    var checksum = false
    /// The frame's latest output, at least its window of it, which matches
    /// copy from.
    var history: [UInt8] = []

    /// Reads the frame header; returns where the first block starts.
    mutating func header(_ input: UnsafeBufferPointer<UInt8>, at start: Int, maximumWindow: Int) throws -> Int {
      var position = start
      let descriptor = try byte(input, position)
      position += 1
      let sizeFlag = Int(descriptor >> 6)
      let singleSegment = descriptor & 0x20 != 0
      checksum = descriptor & 0x04 != 0
      let dictionaryFlag = Int(descriptor & 0x03)
      guard descriptor & 0x08 == 0 else { throw Failure("reserved bit set") }
      if !singleSegment {
        let window = Int(try byte(input, position))
        position += 1
        let base = 1 << (10 + (window >> 3))
        windowSize = base + base / 8 * (window & 7)
      }
      guard dictionaryFlag == 0 else { throw Failure("dictionaries are not supported") }
      let sizeBytes = [singleSegment ? 1 : 0, 2, 4, 8][sizeFlag]
      if singleSegment {
        var size = 0
        for index in 0..<sizeBytes {
          let value = Int(try byte(input, position + index))
          guard index < 7 || value < 0x80 else { throw Failure("window too large") }
          size |= value << (8 * index)
        }
        windowSize = sizeBytes == 2 ? size + 256 : size
      }
      position += sizeBytes
      guard windowSize <= maximumWindow else { throw Failure("window too large") }
      return position
    }

    /// Decodes the block at `start`: its bytes, where the next block or frame
    /// starts, and whether it was the frame's last.
    mutating func nextBlock(_ input: UnsafeBufferPointer<UInt8>, at start: Int) throws -> ([UInt8], Int, Bool) {
      var position = start
      guard input.count - position >= 3 else { throw Failure("truncated block header") }
      let header = Int(input[position]) | Int(input[position + 1]) << 8 | Int(input[position + 2]) << 16
      position += 3
      let last = header & 1 != 0
      let size = header >> 3
      guard size <= maximumBlock else { throw Failure("block too large") }
      let blockStart = history.count
      switch (header >> 1) & 3 {
      case 0:
        guard input.count - position >= size else { throw Failure("truncated raw block") }
        history.append(contentsOf: input[position..<(position + size)])
        position += size
      case 1:
        history.append(contentsOf: repeatElement(try byte(input, position), count: size))
        position += 1
      case 2:
        guard input.count - position >= size else { throw Failure("truncated compressed block") }
        var output: [UInt8] = []
        swap(&output, &history)
        try block(UnsafeBufferPointer(rebasing: input[position..<(position + size)]), into: &output)
        swap(&output, &history)
        position += size
      default:
        throw Failure("reserved block type")
      }
      let bytes = Array(history[blockStart...])
      // Only the window is ever referred back to; the rest is let go, a
      // window's worth at a time.
      let keep = max(windowSize, 1)
      if history.count > 2 * keep + maximumBlock { history.removeFirst(history.count - keep) }
      if last {
        if checksum { position += 4 }
        guard position <= input.count else { throw Failure("truncated frame") }
      }
      return (bytes, position, last)
    }

    private mutating func block(_ input: UnsafeBufferPointer<UInt8>, into output: inout [UInt8]) throws {
      let blockStart = output.count
      var position = 0
      let literals = try readLiterals(input, &position)
      let sequences = try readSequences(input, &position)
      var literal = 0
      for sequence in sequences {
        guard sequence.literalLength <= literals.count - literal else { throw Failure("literals overrun") }
        try room(sequence.literalLength + sequence.matchLength, after: blockStart, in: output)
        output.append(contentsOf: literals[literal..<(literal + sequence.literalLength)])
        literal += sequence.literalLength
        let offset = resolve(sequence)
        guard offset > 0, offset <= min(output.count, windowSize) else { throw Failure("match before the start") }
        // Byte by byte from the front, so a match may overlap what it writes.
        let from = output.count - offset
        let to = output.count
        output.append(contentsOf: repeatElement(0, count: sequence.matchLength))
        output.withUnsafeMutableBufferPointer { buffer in
          for index in 0..<sequence.matchLength { buffer[to + index] = buffer[from + index] }
        }
      }
      try room(literals.count - literal, after: blockStart, in: output)
      output.append(contentsOf: literals[literal...])
    }

    /// Throws unless `count` more bytes keep the block since `start` within
    /// the format's limit.
    private func room(_ count: Int, after start: Int, in output: [UInt8]) throws {
      guard count >= 0, output.count - start + count <= maximumBlock else { throw Failure("output too large") }
    }

    /// The match offset of a sequence, keeping the three repeat offsets.
    private mutating func resolve(_ sequence: Sequence) -> Int {
      let value = sequence.offsetValue
      if value > 3 {
        repeats = [value - 3, repeats[0], repeats[1]]
        return repeats[0]
      }
      let index = sequence.literalLength == 0 ? value : value - 1
      switch index {
      case 0: return repeats[0]
      case 1: repeats = [repeats[1], repeats[0], repeats[2]]
      case 2: repeats = [repeats[2], repeats[0], repeats[1]]
      default: repeats = [repeats[0] - 1, repeats[0], repeats[1]]
      }
      return repeats[0]
    }

    // MARK: Literals

    private mutating func readLiterals(_ input: UnsafeBufferPointer<UInt8>, _ position: inout Int) throws -> [UInt8] {
      let first = try byte(input, position)
      let type = first & 3
      let format = (first >> 2) & 3
      if type < 2 {
        let size: Int
        switch format {
        case 0, 2:
          size = Int(first >> 3)
          position += 1
        case 1:
          size = Int(first >> 4) + Int(try byte(input, position + 1)) << 4
          position += 2
        default:
          size = Int(first >> 4) + Int(try byte(input, position + 1)) << 4 + Int(try byte(input, position + 2)) << 12
          position += 3
        }
        guard size <= maximumBlock else { throw Failure("literals too large") }
        if type == 1 {
          let value = try byte(input, position)
          position += 1
          return [UInt8](repeating: value, count: size)
        }
        guard input.count - position >= size else { throw Failure("truncated literals") }
        defer { position += size }
        return Array(input[position..<(position + size)])
      }
      let headerBytes = [3, 3, 4, 5][Int(format)]
      let bits = [10, 10, 14, 18][Int(format)]
      var header = 0
      for index in 0..<headerBytes { header |= Int(try byte(input, position + index)) << (8 * index) }
      position += headerBytes
      let regenerated = (header >> 4) & ((1 << bits) - 1)
      let compressed = (header >> (4 + bits)) & ((1 << bits) - 1)
      guard regenerated <= maximumBlock else { throw Failure("literals too large") }
      // Four streams each hold at least one of the first three quarters.
      guard format == 0 || regenerated >= 6 else { throw Failure("too few literals for four streams") }
      guard input.count - position >= compressed else { throw Failure("truncated compressed literals") }
      var data = UnsafeBufferPointer(rebasing: input[position..<(position + compressed)])
      position += compressed
      if type == 2 {
        let (table, used) = try HuffmanTable.read(data)
        huffman = table
        data = UnsafeBufferPointer(rebasing: data[used...])
      }
      guard let huffman else { throw Failure("no Huffman table to repeat") }
      if format == 0 { return try huffman.decode(data, count: regenerated) }
      guard data.count >= 6 else { throw Failure("truncated jump table") }
      let sizes = [Int(data[0]) | Int(data[1]) << 8, Int(data[2]) | Int(data[3]) << 8, Int(data[4]) | Int(data[5]) << 8]
      let fourth = data.count - 6 - sizes.reduce(0, +)
      guard fourth >= 0 else { throw Failure("bad jump table") }
      let each = (regenerated + 3) / 4
      var result: [UInt8] = []
      result.reserveCapacity(regenerated)
      var start = 6
      for (index, size) in (sizes + [fourth]).enumerated() {
        let count = index < 3 ? each : regenerated - 3 * each
        result += try huffman.decode(UnsafeBufferPointer(rebasing: data[start..<(start + size)]), count: count)
        start += size
      }
      return result
    }

    // MARK: Sequences

    private mutating func readSequences(_ input: UnsafeBufferPointer<UInt8>, _ position: inout Int) throws -> [Sequence] {
      let first = Int(try byte(input, position))
      let count: Int
      switch first {
      case 0:
        return []
      case ..<128:
        count = first
        position += 1
      case ..<255:
        count = (first - 128) << 8 + Int(try byte(input, position + 1))
        position += 2
      default:
        count = Int(try byte(input, position + 1)) + Int(try byte(input, position + 2)) << 8 + 0x7F00
        position += 3
      }
      let modes = try byte(input, position)
      position += 1
      literalLengths = try table(mode: modes >> 6, kind: .literalLength, previous: literalLengths, input, &position)
      offsets = try table(mode: (modes >> 4) & 3, kind: .offset, previous: offsets, input, &position)
      matchLengths = try table(mode: (modes >> 2) & 3, kind: .matchLength, previous: matchLengths, input, &position)
      guard let literalLengths, let offsets, let matchLengths else { throw Failure("no sequence table") }
      var bits = try BackwardBits(UnsafeBufferPointer(rebasing: input[position...]))
      position = input.count
      var literalState = bits.read(literalLengths.log)
      var offsetState = bits.read(offsets.log)
      var matchState = bits.read(matchLengths.log)
      var sequences: [Sequence] = []
      sequences.reserveCapacity(count)
      for index in 0..<count {
        let offsetCode = Int(offsets.entries[offsetState].symbol)
        let matchCode = Int(matchLengths.entries[matchState].symbol)
        let literalCode = Int(literalLengths.entries[literalState].symbol)
        guard offsetCode < 32, matchCode < Self.matchBase.count, literalCode < Self.literalBase.count else {
          throw Failure("bad sequence code")
        }
        let offsetValue = 1 << offsetCode + bits.read(offsetCode)
        let matchLength = Self.matchBase[matchCode] + bits.read(Self.matchBits[matchCode])
        let literalLength = Self.literalBase[literalCode] + bits.read(Self.literalBits[literalCode])
        sequences.append(Sequence(literalLength: literalLength, matchLength: matchLength, offsetValue: offsetValue))
        if index + 1 < count {
          literalState = literalLengths.next(literalState, &bits)
          matchState = matchLengths.next(matchState, &bits)
          offsetState = offsets.next(offsetState, &bits)
        }
      }
      guard !bits.overflowed else { throw Failure("sequence bits overrun") }
      return sequences
    }

    private func table(mode: UInt8, kind: FSETable.Kind, previous: FSETable?, _ input: UnsafeBufferPointer<UInt8>,
                       _ position: inout Int) throws -> FSETable {
      switch mode {
      case 0:
        return kind.predefined
      case 1:
        let symbol = try byte(input, position)
        position += 1
        return FSETable(log: 0, entries: [FSETable.Entry(symbol: symbol, bits: 0, base: 0)])
      case 2:
        let (counts, log, used) = try FSETable.readCounts(UnsafeBufferPointer(rebasing: input[position...]),
                                                          maxLog: kind.maxLog, maxSymbol: kind.maxSymbol)
        position += used
        return try FSETable(counts: counts, log: log)
      default:
        guard let previous else { throw Failure("no sequence table to repeat") }
        return previous
      }
    }

    static let literalBase = Array(0..<16) + [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192,
                                              16384, 32768, 65536]
    static let literalBits = [Int](repeating: 0, count: 16) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    static let matchBase = Array(3..<35) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195,
                                            16387, 32771, 65539]
    static let matchBits = [Int](repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
  }

  private struct Sequence {
    let literalLength: Int
    let matchLength: Int
    let offsetValue: Int
  }

  private static func byte(_ input: UnsafeBufferPointer<UInt8>, _ index: Int) throws -> UInt8 {
    guard index < input.count else { throw Failure("truncated") }
    return input[index]
  }

  private static func highBit(_ value: Int) -> Int { Int.bitWidth - 1 - value.leadingZeroBitCount }

  // MARK: Bit streams

  /// A stream read from its last bit towards its first, after the marker bit.
  private struct BackwardBits {
    private let bytes: [UInt8]
    /// Bits left to read; below zero once read past the start.
    private(set) var position: Int

    init(_ data: UnsafeBufferPointer<UInt8>) throws {
      guard let last = data.last, last != 0 else { throw Failure("bit stream has no end marker") }
      bytes = Array(data) + [UInt8](repeating: 0, count: 8)
      position = (data.count - 1) * 8 + Zstd.highBit(Int(last))
    }

    var overflowed: Bool { position < 0 }

    /// The next `count` bits without reading them; bits before the start are zero.
    func peek(_ count: Int) -> Int {
      guard count > 0 else { return 0 }
      let low = position - count
      if low >= 0 { return word(at: low) & ((1 << count) - 1) }
      guard position > 0 else { return 0 }
      return (word(at: 0) & ((1 << position) - 1)) << -low
    }

    mutating func read(_ count: Int) -> Int {
      let value = peek(count)
      position -= count
      return value
    }

    mutating func skip(_ count: Int) { position -= count }

    private func word(at bit: Int) -> Int {
      let index = bit >> 3
      var value: UInt64 = 0
      for offset in 0..<8 { value |= UInt64(bytes[index + offset]) << (8 * offset) }
      return Int(truncatingIfNeeded: value >> UInt64(bit & 7))
    }
  }

  /// A stream read from its first bit, for table descriptions.
  private struct ForwardBits {
    let data: UnsafeBufferPointer<UInt8>
    var position = 0

    func peek(_ count: Int) -> Int {
      var value = 0
      for offset in 0..<count {
        let bit = position + offset
        let index = bit >> 3
        guard index < data.count else { break }
        value |= Int((data[index] >> (bit & 7)) & 1) << offset
      }
      return value
    }

    mutating func read(_ count: Int) -> Int {
      defer { position += count }
      return peek(count)
    }

    var bytesUsed: Int { (position + 7) / 8 }
  }

  // MARK: Finite state entropy

  private struct FSETable {
    struct Entry {
      let symbol: UInt8
      let bits: Int
      let base: Int
    }

    let log: Int
    let entries: [Entry]

    init(log: Int, entries: [Entry]) {
      self.log = log
      self.entries = entries
    }

    init(counts: [Int], log: Int) throws {
      let size = 1 << log
      var symbols = [UInt8](repeating: 0, count: size)
      var next = [Int](repeating: 0, count: counts.count)
      var high = size - 1
      for (symbol, count) in counts.enumerated() where count == -1 {
        symbols[high] = UInt8(symbol)
        high -= 1
        next[symbol] = 1
      }
      let step = (size >> 1) + (size >> 3) + 3
      var position = 0
      for (symbol, count) in counts.enumerated() where count > 0 {
        next[symbol] = count
        for _ in 0..<count {
          symbols[position] = UInt8(symbol)
          repeat { position = (position + step) & (size - 1) } while position > high
        }
      }
      guard position == 0 else { throw Failure("bad entropy table") }
      self.log = log
      entries = symbols.map { symbol in
        let state = next[Int(symbol)]
        next[Int(symbol)] += 1
        let bits = log - Zstd.highBit(state)
        return Entry(symbol: symbol, bits: bits, base: (state << bits) - size)
      }
    }

    func next(_ state: Int, _ bits: inout BackwardBits) -> Int {
      let entry = entries[state]
      return entry.base + bits.read(entry.bits)
    }

    /// Reads a table description: the normalized counts, the accuracy log
    /// and the bytes it took.
    static func readCounts(_ data: UnsafeBufferPointer<UInt8>, maxLog: Int, maxSymbol: Int) throws -> ([Int], Int, Int) {
      var bits = ForwardBits(data: data)
      let log = bits.read(4) + 5
      guard log <= maxLog else { throw Failure("accuracy too high") }
      var remaining = (1 << log) + 1
      var threshold = 1 << log
      var width = log + 1
      var counts: [Int] = []
      var previousZero = false
      while remaining > 1 && counts.count <= maxSymbol {
        if previousZero {
          var zeros = 0
          while true {
            let flag = bits.read(2)
            zeros += flag
            if flag != 3 { break }
          }
          counts += [Int](repeating: 0, count: zeros)
          guard counts.count <= maxSymbol else { break }
        }
        let max = (2 * threshold - 1) - remaining
        var count: Int
        if bits.peek(width - 1) & (threshold - 1) < max {
          count = bits.read(width - 1) & (threshold - 1)
        } else {
          count = bits.read(width) & (2 * threshold - 1)
          if count >= threshold { count -= max }
        }
        count -= 1
        remaining -= abs(count)
        guard remaining >= 1 else { throw Failure("bad entropy table description") }
        counts.append(count)
        previousZero = count == 0
        while remaining < threshold {
          width -= 1
          threshold >>= 1
        }
      }
      guard remaining == 1, bits.bytesUsed <= data.count else { throw Failure("bad entropy table description") }
      return (counts, log, bits.bytesUsed)
    }

    enum Kind {
      case literalLength, offset, matchLength

      var maxLog: Int { self == .offset ? 8 : 9 }
      var maxSymbol: Int {
        switch self {
        case .literalLength: 35
        case .offset: 31
        case .matchLength: 52
        }
      }

      var predefined: FSETable {
        switch self {
        case .literalLength: FSETable.literalLengths
        case .offset: FSETable.offsets
        case .matchLength: FSETable.matchLengths
        }
      }
    }

    // The predefined distributions of RFC 8878.
    // swiftlint:disable force_try
    static let literalLengths = try! FSETable(counts: [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3,
                                                       2, 1, 1, 1, 1, 1, -1, -1, -1, -1], log: 6)
    static let matchLengths = try! FSETable(counts: [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                                     1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
                                                     -1, -1], log: 6)
    static let offsets = try! FSETable(counts: [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
                                                -1, -1, -1], log: 5)
    // swiftlint:enable force_try
  }

  // MARK: Huffman

  private struct HuffmanTable {
    let log: Int
    let symbols: [UInt8]
    let lengths: [UInt8]

    /// Reads a tree description; returns the table and the bytes it took.
    static func read(_ data: UnsafeBufferPointer<UInt8>) throws -> (HuffmanTable, Int) {
      guard let header = data.first.map(Int.init) else { throw Failure("no Huffman tree") }
      var weights: [Int] = []
      let used: Int
      if header >= 128 {
        let count = header - 127
        used = 1 + (count + 1) / 2
        guard data.count >= used else { throw Failure("truncated Huffman weights") }
        for index in 0..<count {
          let value = Int(data[1 + index / 2])
          weights.append(index % 2 == 0 ? value >> 4 : value & 15)
        }
      } else {
        used = 1 + header
        guard data.count >= used else { throw Failure("truncated Huffman weights") }
        let body = UnsafeBufferPointer(rebasing: data[1..<used])
        let (counts, log, tableBytes) = try FSETable.readCounts(body, maxLog: 6, maxSymbol: 255)
        let table = try FSETable(counts: counts, log: log)
        var bits = try BackwardBits(UnsafeBufferPointer(rebasing: body[tableBytes...]))
        var first = bits.read(log)
        var second = bits.read(log)
        while weights.count < 255 {
          weights.append(Int(table.entries[first].symbol))
          first = table.next(first, &bits)
          if bits.overflowed {
            weights.append(Int(table.entries[second].symbol))
            break
          }
          weights.append(Int(table.entries[second].symbol))
          second = table.next(second, &bits)
          if bits.overflowed {
            weights.append(Int(table.entries[first].symbol))
            break
          }
        }
      }
      // Real weights stop at 11, and the one left implied is symbol 255 at most.
      guard weights.count <= 255, weights.allSatisfy({ $0 <= 11 }) else { throw Failure("bad Huffman weights") }
      let total = weights.reduce(0) { $0 + ($1 > 0 ? 1 << ($1 - 1) : 0) }
      guard total > 0 else { throw Failure("empty Huffman tree") }
      let log = Zstd.highBit(total) + 1
      guard log <= 11 else { throw Failure("Huffman tree too deep") }
      let rest = (1 << log) - total
      guard rest & (rest - 1) == 0 else { throw Failure("bad Huffman weights") }
      weights.append(Zstd.highBit(rest) + 1)
      var rankCount = [Int](repeating: 0, count: log + 2)
      for weight in weights where weight > 0 { rankCount[weight] += 1 }
      var rankStart = [Int](repeating: 0, count: log + 2)
      var next = 0
      for weight in 1...log {
        rankStart[weight] = next
        next += rankCount[weight] << (weight - 1)
      }
      var symbols = [UInt8](repeating: 0, count: 1 << log)
      var lengths = [UInt8](repeating: 0, count: 1 << log)
      for (symbol, weight) in weights.enumerated() where weight > 0 {
        let span = 1 << (weight - 1)
        for index in rankStart[weight]..<(rankStart[weight] + span) {
          symbols[index] = UInt8(symbol)
          lengths[index] = UInt8(log + 1 - weight)
        }
        rankStart[weight] += span
      }
      return (HuffmanTable(log: log, symbols: symbols, lengths: lengths), used)
    }

    func decode(_ data: UnsafeBufferPointer<UInt8>, count: Int) throws -> [UInt8] {
      var bits = try BackwardBits(data)
      var result = [UInt8](repeating: 0, count: count)
      for index in 0..<count {
        let entry = bits.peek(log)
        result[index] = symbols[entry]
        bits.skip(Int(lengths[entry]))
      }
      guard bits.position == 0 else { throw Failure("Huffman stream length mismatch") }
      return result
    }
  }
}
