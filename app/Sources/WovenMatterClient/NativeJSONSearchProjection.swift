import Foundation

/// Decode exposed JSON string content for search without retaining an entire
/// native record. Keys and values are separated so unrelated strings cannot
/// form a fabricated word. Raw archive bytes remain the source of truth.
struct NativeJSONSearchProjection: Sendable {
    private enum Stage: Sendable {
        case outside, string, escape
        case unicode(digits: Int, value: UInt16)
        case lowSlash(high: UInt16), lowU(high: UInt16)
        case lowUnicode(high: UInt16, digits: Int, value: UInt16)
    }
    private var stage = Stage.outside
    private var hasString = false
    private var utf8 = Data()
    private var continuationCount = 0

    mutating func consume(_ data: Data) throws -> Data {
        var output = Data()
        output.reserveCapacity(data.count + 4)
        for byte in data {
            switch stage {
            case .outside:
                if byte == 34 {
                    if hasString { output.append(10) }
                    hasString = true; stage = .string
                }
            case .string:
                if continuationCount > 0 {
                    guard (128...191).contains(byte) else { throw PiNativeHistoryFrame.Failure.malformed }
                    if utf8.count == 1 {
                        let leading = utf8[0]
                        guard !(leading == 224 && byte < 160), !(leading == 237 && byte > 159),
                              !(leading == 240 && byte < 144), !(leading == 244 && byte > 143) else {
                            throw PiNativeHistoryFrame.Failure.malformed
                        }
                    }
                    utf8.append(byte); continuationCount -= 1
                    if continuationCount == 0 {
                        output.append(utf8); utf8.removeAll(keepingCapacity: true)
                    }
                } else if byte == 34 { stage = .outside }
                else if byte == 92 { stage = .escape }
                else if byte < 128 {
                    guard byte >= 32 else { throw PiNativeHistoryFrame.Failure.malformed }
                    output.append(byte)
                } else {
                    if (194...223).contains(byte) { continuationCount = 1 }
                    else if (224...239).contains(byte) { continuationCount = 2 }
                    else if (240...244).contains(byte) { continuationCount = 3 }
                    else { throw PiNativeHistoryFrame.Failure.malformed }
                    utf8.append(byte)
                }
            case .escape:
                switch byte {
                case 34, 47, 92: output.append(byte); stage = .string
                case 98: output.append(8); stage = .string
                case 102: output.append(12); stage = .string
                case 110: output.append(10); stage = .string
                case 114: output.append(13); stage = .string
                case 116: output.append(9); stage = .string
                case 117: stage = .unicode(digits: 0, value: 0)
                default: throw PiNativeHistoryFrame.Failure.malformed
                }
            case .unicode(let digits, let value):
                guard let nibble = Self.hex(byte) else { throw PiNativeHistoryFrame.Failure.malformed }
                let next = (value << 4) | nibble
                if digits == 3 {
                    if (0xD800...0xDBFF).contains(next) { stage = .lowSlash(high: next) }
                    else {
                        guard !(0xDC00...0xDFFF).contains(next), let scalar = UnicodeScalar(UInt32(next)) else {
                            throw PiNativeHistoryFrame.Failure.malformed
                        }
                        output.append(contentsOf: String(scalar).utf8); stage = .string
                    }
                } else { stage = .unicode(digits: digits + 1, value: next) }
            case .lowSlash(let high):
                guard byte == 92 else { throw PiNativeHistoryFrame.Failure.malformed }
                stage = .lowU(high: high)
            case .lowU(let high):
                guard byte == 117 else { throw PiNativeHistoryFrame.Failure.malformed }
                stage = .lowUnicode(high: high, digits: 0, value: 0)
            case .lowUnicode(let high, let digits, let value):
                guard let nibble = Self.hex(byte) else { throw PiNativeHistoryFrame.Failure.malformed }
                let next = (value << 4) | nibble
                if digits == 3 {
                    guard (0xDC00...0xDFFF).contains(next),
                          let scalar = UnicodeScalar(0x10000 + ((UInt32(high) - 0xD800) << 10) + UInt32(next) - 0xDC00) else {
                        throw PiNativeHistoryFrame.Failure.malformed
                    }
                    output.append(contentsOf: String(scalar).utf8); stage = .string
                } else { stage = .lowUnicode(high: high, digits: digits + 1, value: next) }
            }
        }
        return output
    }

    /// A caller must finish at the native record boundary, rather than silently
    /// omitting the suffix of an incomplete escape or Unicode scalar.
    func finish() throws {
        guard case .outside = stage, continuationCount == 0, utf8.isEmpty else {
            throw PiNativeHistoryFrame.Failure.malformed
        }
    }

    private static func hex(_ byte: UInt8) -> UInt16? {
        if (48...57).contains(byte) { return UInt16(byte - 48) }
        if (65...70).contains(byte) { return UInt16(byte - 65 + 10) }
        if (97...102).contains(byte) { return UInt16(byte - 97 + 10) }
        return nil
    }
}
