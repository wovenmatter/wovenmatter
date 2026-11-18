import XCTest
@testable import LibraryClient
import WovenMatterShared

final class MobileArtifactPreviewTests: XCTestCase {
  func testCachedArtifactShowsSavedInputsWithoutOpeningAWriteOrNetworkBridge() {
    let state = ArtifactStateSnapshot(values: ["form:text:title:0": .string("Saved planner"), "app:count": .number(3)],
      versions: ["form:text:title:0": 2, "app:count": 1])
    let html = MobileArtifactPreview.renderedHTML(html: "<input id='title'><button>Switch tab</button>", state: state)
    XCTAssertTrue(html.contains("Saved planner"))
    XCTAssertTrue(html.contains("\"editable\":false"))
    XCTAssertTrue(html.contains(ArtifactStateJavaScript.bootstrap))
    XCTAssertTrue(html.contains("default-src 'none'"))
    XCTAssertTrue(html.contains("form-action 'none'"))
  }

  func testSavedInputCannotEscapeItsBootstrapScript() {
    let value = "</script><script>injected()</script>\u{2028}"
    let html = MobileArtifactPreview.renderedHTML(html: "<main>Planner</main>",
      state: .init(values: ["app:text": .string(value)], versions: ["app:text": 1]))
    XCTAssertFalse(html.contains(value))
    XCTAssertTrue(html.contains("\\u003c"))
    XCTAssertTrue(html.contains("\\u2028"))
  }
}
