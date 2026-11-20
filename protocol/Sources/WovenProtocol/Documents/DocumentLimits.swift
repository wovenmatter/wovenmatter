import Foundation

/// Size limits a document must fit in before it is saved or opened.
public enum DocumentLimits {
  public static let maximumNoteBytes = 4 * 1_024 * 1_024
  public static let maximumBoardBytes = 1 * 1_024 * 1_024
}
