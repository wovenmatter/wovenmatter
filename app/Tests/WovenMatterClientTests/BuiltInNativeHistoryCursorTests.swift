import Testing
@testable import WovenMatterClient

struct BuiltInNativeHistoryCursorTests {
    @Test func oversizedRecordCursorIsOrderedAndRoundTrips() throws {
        let start = try BuiltInNativeHistoryCursor(.integer(4))
        let partial = try BuiltInNativeHistoryCursor(.object(["record": .integer(4), "byteOffset": .integer(262_144)]))
        let nextPart = try BuiltInNativeHistoryCursor(.object(["record": .integer(4), "byteOffset": .integer(524_288)]))
        let nextRecord = try BuiltInNativeHistoryCursor(.integer(5))
        #expect(start < partial && partial < nextPart && nextPart < nextRecord)
        #expect(try BuiltInNativeHistoryCursor(partial.value) == partial)
        #expect(try BuiltInNativeHistoryCursor(.object(["record": .integer(4), "byteOffset": .integer(0)])) == start)
    }

    @Test func rejectsMalformedOrUnsafeCursors() {
        let invalid: [ACPJSONValue] = [
            .integer(-1), .integer(9_007_199_254_740_992), .string("cursor"),
            .object(["record": .integer(0)]),
            .object(["record": .integer(0), "byteOffset": .integer(-1)]),
            .object(["record": .integer(0), "byteOffset": .integer(1), "extra": .integer(1)]),
        ]
        for value in invalid {
            #expect(throws: LocalACPClientError.self) { try BuiltInNativeHistoryCursor(value) }
        }
    }
}
