import Foundation
import CryptoKit
import XCTest
@testable import EmbeddedExecution

final class EmbeddedExecutionTests: XCTestCase {
  private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("woven-embedded-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    addTeardownBlock { try? FileManager.default.removeItem(at:root) }
    return root
  }

  func testRejectsEscapingAndReservedPaths() throws {
    for path in ["", "/tmp/file", "../file", "a/../file", "a//file", ".woven-execution/private", ".WOVEN-EXECUTION/private", "a/./b", "file\0tail"] {
      XCTAssertThrowsError(try EmbeddedWorkspace.validate(path),path)
    }
    try EmbeddedWorkspace.validate("nested/hello world.csv")
  }

  func testSnapshotRejectsSymlinksAndResourceOverflow() throws {
    let root = try directory()
    try Data("abc".utf8).write(to:root.appendingPathComponent("input"))
    XCTAssertThrowsError(try EmbeddedWorkspace.read(root,maxBytes:2,maxFiles:10))
    try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:root.appendingPathComponent("input"))
    XCTAssertThrowsError(try EmbeddedWorkspace.read(root,maxBytes:100,maxFiles:10))
  }

  func testWorkerResultCannotClaimDirectoryAndFileSamePath() throws {
    XCTAssertThrowsError(try EmbeddedWorkspace.decode(files:[["path":"a","data":"YQ=="]],directories:["a"],maxBytes:100,maxFiles:10))
    XCTAssertThrowsError(try EmbeddedWorkspace.decode(files:[["path":"a","data":"YQ=="],["path":"a/b","data":"Yg=="]],directories:[],maxBytes:100,maxFiles:10))
    XCTAssertThrowsError(try EmbeddedWorkspace.decode(files:[["path":"a","data":"***"]],directories:[],maxBytes:100,maxFiles:10))
    XCTAssertThrowsError(try EmbeddedWorkspace.decode(files:[["path":"a/b/c/d","data":"YQ=="]],directories:[],maxBytes:100,maxFiles:2))
    XCTAssertThrowsError(try EmbeddedWorkspace.decode(files:[["path":"A","data":"YQ=="],["path":"a","data":"Yg=="]],directories:[],maxBytes:100,maxFiles:10))
    XCTAssertThrowsError(try EmbeddedWorkspace.decode(files:[["path":"FOO/a","data":"YQ=="],["path":"foo/b","data":"Yg=="]],directories:[],maxBytes:100,maxFiles:10))
  }

  func testCommitAppliesCompleteSnapshotWithAtomicReceipt() throws {
    let root = try directory(), id = UUID()
    try Data("old".utf8).write(to:root.appendingPathComponent("before"))
    let original = try EmbeddedWorkspace.read(root,maxBytes:100,maxFiles:10)
    let result = try EmbeddedWorkspace.decode(files:[["path":"nested/after","data":Data("new".utf8).base64EncodedString()]],directories:[],maxBytes:100,maxFiles:10)
    try result.commit(to:root,replacing:original,receipt:Data("receipt".utf8),requestID:id,maxBytes:100,maxFiles:10)
    XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("before").path))
    XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("nested/after"),encoding:.utf8),"new")
    XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(".woven-execution/\(id.uuidString)/receipt.json"),encoding:.utf8),"receipt")
    let actual = try EmbeddedWorkspace.read(root,maxBytes:100,maxFiles:10)
    XCTAssertEqual(actual.directories,result.directories)
    XCTAssertEqual(actual.files,result.files)
    XCTAssertEqual(actual.fingerprint,result.fingerprint)
  }

  func testConcurrentChangesPreservedWithoutPartialCommit() throws {
    let root = try directory()
    try Data("initial".utf8).write(to:root.appendingPathComponent("shared"))
    let original = try EmbeddedWorkspace.read(root,maxBytes:100,maxFiles:10)
    try Data("new native edit".utf8).write(to:root.appendingPathComponent("shared"))
    let result = EmbeddedWorkspace(files:["other":Data("worker output".utf8)],directories:[])
    XCTAssertThrowsError(try result.commit(to:root,replacing:original,receipt:Data(),requestID:UUID(),maxBytes:100,maxFiles:10))
    XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("shared"),encoding:.utf8),"new native edit")
    XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("other").path))
  }


  @MainActor
  func testBundledRuntimeResourcesAreAvailableWithoutNetwork() throws {
    let resources = EmbeddedCommandExecutor().resourceURL
    for name in ["worker.js","commands.py","python_stdlib.zip","pyodide.asm.wasm","pyodide-lock.json","provenance.json"] {
      XCTAssertTrue(FileManager.default.fileExists(atPath:resources.appendingPathComponent(name).path),name)
    }
    let lock = try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("pyodide-lock.json"))) as! [String:Any]
    XCTAssertEqual((lock["packages"] as? [String:Any])?.count,0)
  }

  @MainActor
  func testAcceptedWithoutReceiptIsNeverAutomaticallyReplayed() async throws {
    let root = try directory(), request = EmbeddedCommandRequest(id:UUID(),argv:["python","-c","print(42)"])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let digest = SHA256.hash(data:try encoder.encode(request)).map { String(format:"%02x",$0) }.joined()
    let job = root.appendingPathComponent(".woven-execution/\(request.id.uuidString)")
    try FileManager.default.createDirectory(at:job,withIntermediateDirectories:true)
    let marker: [String:Any] = ["requestDigest":digest,"acceptedAt":Date().timeIntervalSinceReferenceDate]
    try JSONSerialization.data(withJSONObject:marker).write(to:job.appendingPathComponent("accepted.json"))
    do {
      _ = try await EmbeddedCommandExecutor().run(request,workspaceURL:root) { _,_ in XCTFail("Must not reach native tools"); return "{}" }
      XCTFail("Accepted command must not rerun without a receipt")
    } catch { XCTAssertTrue(error.localizedDescription.contains("will not be replayed automatically")) }
  }

  @MainActor
  func testNestedCLIIDsStableAcrossReplay() {
    let id = UUID()
    let first = EmbeddedCommandExecutor.commandID(request:id,sequence:1)
    XCTAssertNotNil(UUID(uuidString:first))
    XCTAssertEqual(first,EmbeddedCommandExecutor.commandID(request:id,sequence:1))
    XCTAssertNotEqual(first,EmbeddedCommandExecutor.commandID(request:id,sequence:2))
    XCTAssertNotEqual(first,EmbeddedCommandExecutor.commandID(request:UUID(),sequence:1))
  }
}
