import Foundation
import WovenMatterCompanion

public enum WovenAutomationOutput {
  /// Export on the caller's machine. The automation host never opens this path.
  public static func exportImage(_ response: WovenMatterToolResponse, to url: URL) throws -> WovenMatterToolResponse {
    guard var result = response.result?.objectValue, var content = result["content"]?.arrayValue,
      let index = content.firstIndex(where: { $0.objectValue?["type"]?.stringValue == "image" }),
      let encoded = content[index].objectValue?["data"]?.stringValue,
      let bytes = Data(base64Encoded: encoded), bytes.count <= 1_048_576 else { throw WorkspaceToolError.invalid("This response has no bounded screenshot image.") }
    try bytes.write(to: url, options: .withoutOverwriting)
    content[index] = .object(["type": .string("text"), "text": .string("Screenshot saved: " + url.path)])
    result["content"] = .array(content)
    return .init(success: response.success, result: .object(result), error: response.error, code: response.code, silent: response.silent, requestID: response.requestID)
  }
}
