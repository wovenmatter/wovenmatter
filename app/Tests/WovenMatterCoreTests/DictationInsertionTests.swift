import Foundation
import Testing
@testable import WovenMatterCore

@Suite struct DictationInsertionTests {
    @Test func selectionAndUnicodeUseNativeUTF16Offsets() {
        let insertion = DictationInsertion(text: "Hi 🌿 old text", selection: NSRange(location: 6, length: 3))
        #expect(insertion.range(in: "Hi 🌿 old text") == NSRange(location: 6, length: 3))
        #expect(insertion.range(in: "Hello 🌿 old text") == NSRange(location: 9, length: 3))
    }
    @Test func unrelatedEditsSurviveWhileOverlappingEditsRequireExplicitInsertion() {
        let insertion = DictationInsertion(text: "one two three", selection: NSRange(location: 4, length: 3))
        #expect(insertion.range(in: "one two three!") == insertion.selection)
        #expect(insertion.range(in: "one changed three") == nil)
        #expect(DictationInsertion(text: "abc", selection: NSRange(location: 3, length: 0)).range(in: "abcd") == nil)
        #expect(DictationInsertion(text: "", selection: NSRange(location: NSNotFound, length: 0)).range(in: "") == nil)
    }
}
