import Foundation
import Testing
import WovenProtocol
@testable import WovenServerKit

@Test
func aPagesLocalImagesAreEmbeddedOnceAndAMissingOneIsNamed() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-page-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 24)
  let image = folder.appendingPathComponent("dot.png").path
  try png.write(to: URL(fileURLWithPath: image))
  let text = folder.appendingPathComponent("notes.png").path
  try Data("not an image".utf8).write(to: URL(fileURLWithPath: text))
  let large = folder.appendingPathComponent("large.png").path
  try (png + Data(count: HTMLPages.imageLimit)).write(to: URL(fileURLWithPath: large))
  let gone = folder.appendingPathComponent("gone.png").path

  let page = try HTMLPages.prepare("""
    <img src="\(image)"><div style='background:url(\(image))'></div><script>const a = `\(image)`</script>
    <img src="//cdn.example.com/a.png"><img src="https://example.com/b.png">
    <img src="\(text)"><img src="\(large)"><img src="\(gone)"><img src="\(gone)">
    """)
  let uri = "data:image/png;base64," + png.base64EncodedString()
  #expect(page.html.components(separatedBy: uri).count == 4)
  #expect(page.html.contains("\"//cdn.example.com/a.png\"") && page.html.contains("\"https://example.com/b.png\""))
  #expect(page.missingImages == [text, large, gone])

  #expect(throws: ToolFailure.self) { try HTMLPages.prepare(String(repeating: "a", count: HTMLPages.authoredLimit + 1)) }
  // Three references to a 10 MiB image make a page over 25 MiB.
  let full = folder.appendingPathComponent("full.png").path
  try (png + Data(count: HTMLPages.imageLimit - png.count)).write(to: URL(fileURLWithPath: full))
  #expect(throws: ToolFailure.self) { try HTMLPages.prepare("<img src='\(full)'><img src='\(full)'><img src='\(full)'>") }
}
