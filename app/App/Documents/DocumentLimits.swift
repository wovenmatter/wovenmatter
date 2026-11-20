import Foundation

/// Size limits a document must fit in before it is saved or opened.
enum DocumentLimits {
    static let maximumNoteBytes = 4 * 1_024 * 1_024
    static let maximumBoardBytes = 1 * 1_024 * 1_024
}
