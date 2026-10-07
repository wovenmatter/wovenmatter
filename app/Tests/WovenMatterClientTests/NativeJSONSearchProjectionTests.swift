import Foundation
import Testing
@testable import WovenMatterClient

struct NativeJSONSearchProjectionTests {
    @Test(arguments: [1, 2, 3, 7, 17, 256 * 1_024])
    func decodesStringsAndEscapedUnicodeAcrossFragments(chunkBytes: Int) throws {
        let source = Data(#"{"tool":"bash","content":"line\nneedle café🧵 日本語 \u00e9 \uD83E\uDDF5 quoted\" slash\/ backslash\\ tab\t NUL\u0000","thinking":"exposed summary"}"#.utf8)
        let native = try #require(try JSONSerialization.jsonObject(with: source) as? [String: String])
        let expected = ["tool", native["tool"]!, "content", native["content"]!, "thinking", native["thinking"]!].joined(separator: "\n")
        var projection = NativeJSONSearchProjection(), restored = Data(), offset = 0
        while offset < source.count {
            let end = min(source.count, offset + chunkBytes)
            let output = try projection.consume(source.subdata(in: offset..<end))
            #expect(String(data: output, encoding: .utf8) != nil)
            restored.append(output); offset = end
        }
        try projection.finish()
        #expect(restored == Data(expected.utf8))
        #expect(String(decoding: restored, as: UTF8.self).contains("\nneedle"))
        #expect(String(decoding: restored, as: UTF8.self).contains("é 🧵"))
        #expect(String(decoding: restored, as: UTF8.self).contains("exposed summary"))
        #expect(!String(decoding: restored, as: UTF8.self).contains("\\u00e9"))
    }

    @Test func keepsEscapedQuotesInsideTheirStringAndSeparatesAdjacentValues() throws {
        var projection = NativeJSONSearchProjection()
        let output = try projection.consume(Data(#"["","quoted\"content","a","b",{"token":"native content","number":123}]"#.utf8))
        try projection.finish()
        #expect(String(decoding: output, as: UTF8.self) == "\nquoted\"content\na\nb\ntoken\nnative content\nnumber")
    }

    @Test func rejectsMalformedEscapesSurrogatesAndLiteralUTF8() throws {
        let malformed = [
            Data(#""\x""#.utf8), Data(#""\u00xz""#.utf8), Data(#""\uDC00""#.utf8),
            Data(#""\uD800x""#.utf8), Data(#""\uD800\u0041""#.utf8),
            Data([34, 0xC0, 0x80, 34]), Data([34, 0xED, 0xA0, 0x80, 34]),
            Data([34, 0xF4, 0x90, 0x80, 0x80, 34]), Data([34, 1, 34]),
        ]
        for source in malformed {
            var projection = NativeJSONSearchProjection()
            #expect(throws: (any Error).self) {
                for byte in source { _ = try projection.consume(Data([byte])) }
                try projection.finish()
            }
        }
    }

    @Test func incompleteSuffixMustFailAtTheRecordBoundary() throws {
        for source in [Data(#""incomplete"#.utf8), Data(#""\u00"#.utf8), Data(#""\uD800\u"#.utf8), Data([34, 0xF0, 0x9F])] {
            var projection = NativeJSONSearchProjection()
            _ = try projection.consume(source)
            #expect(throws: (any Error).self) { try projection.finish() }
        }
    }

}
