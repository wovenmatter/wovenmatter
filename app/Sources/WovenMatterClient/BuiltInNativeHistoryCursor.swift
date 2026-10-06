import Foundation

/// A partial record cursor keeps oversized native copies paged without ever
/// reconstructing the entire record in the desktop process.
struct BuiltInNativeHistoryCursor: Equatable, Comparable {
    let record: Int64
    let byteOffset: Int64

    init(_ value: ACPJSONValue) throws {
        if let record = value.integerValue {
            self.record = record
            byteOffset = 0
        } else if case .object(let fields) = value,
                  Set(fields.keys) == ["record", "byteOffset"],
                  let record = fields["record"]?.integerValue,
                  let byteOffset = fields["byteOffset"]?.integerValue {
            self.record = record
            self.byteOffset = byteOffset
        } else {
            throw LocalACPClientError.invalidResponse("Invalid Built-in native archive cursor")
        }
        let maximumSafeInteger: Int64 = 9_007_199_254_740_991
        guard record >= 0, byteOffset >= 0, record <= maximumSafeInteger, byteOffset <= maximumSafeInteger else {
            throw LocalACPClientError.invalidResponse("Invalid Built-in native archive cursor")
        }
    }

    var value: ACPJSONValue {
        byteOffset == 0 ? .integer(record) : .object([
            "record": .integer(record), "byteOffset": .integer(byteOffset),
        ])
    }

    static func < (left: Self, right: Self) -> Bool {
        left.record < right.record || (left.record == right.record && left.byteOffset < right.byteOffset)
    }
}
