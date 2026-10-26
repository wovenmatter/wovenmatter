import Foundation

@MainActor
final class SmokeRunner {
  private let documents: URL
  private let resourceURL: URL?
  var report: [String: Any] = [:]

  init(documents: URL, resourceURL: URL? = nil) {
    self.documents = documents
    self.resourceURL = resourceURL
  }
  func run() async {
    let root = documents.appendingPathComponent("workspace",isDirectory:true)
    try? FileManager.default.removeItem(at:root)
    try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let writeReport = { [self] in
      try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to: documents.appendingPathComponent("report.json"),options:.atomic)
    }
    do {
      report["runID"] = ProcessInfo.processInfo.environment["WOVEN_EMBEDDED_RUN_ID"] ?? UUID().uuidString
      report["status"] = "running"; writeReport()
      let id = UUID()
      let request = EmbeddedCommandRequest(id:id,argv:["python","-c", "import sys,json,csv,io,sqlite3,pathlib\nprint(sys.version,flush=True)\nrows=list(csv.DictReader(io.StringIO('x,y\\n2,3\\n')))\ndb=sqlite3.connect('test.sqlite'); db.execute('create table sample(value integer)'); db.execute('insert into sample values (?)',(int(rows[0][\"x\"])*int(rows[0][\"y\"]),)); db.commit(); print(db.execute('select value from sample').fetchone()[0]); db.close()\npathlib.Path('result.json').write_text(json.dumps(rows))\nprint(await woven_mcp('woven_notes_list', {}))"])
      let executor = EmbeddedCommandExecutor(resourceURL: resourceURL)
      var calls = 0
      let result = try await executor.run(request,workspaceURL:root,onOutput:{stream,text in
        self.report["lastOutput"] = text; writeReport()
      }) { name, argumentsJSON, requestID in
        calls += 1
        return "{\"notes\":[\"native bridge works\"]}"
      }
      report["python"] = result.stdout; report["exitCode"] = result.exitCode; report["changedFiles"] = result.changedFiles
      guard result.exitCode == 0, result.stdout.contains("native bridge works"), result.changedFiles.contains("test.sqlite") else { throw EmbeddedExecutionError.unavailable("Python smoke assertions failed: " + result.stderr) }
      let replay = try await EmbeddedCommandExecutor(resourceURL: resourceURL).run(request,workspaceURL:root) { _, _, _ in calls += 1; return "{}" }
      report["receiptReplay"] = replay.stdout == result.stdout && calls == 1
      writeReport()
      let read = try await EmbeddedCommandExecutor(resourceURL: resourceURL).run(.init(id:UUID(),argv:["sqlite3","test.sqlite","select value from sample"]),workspaceURL:root) {_,_,_ in "{}"}
      report["sqlitePersistence"] = read.stdout == "[6]\n"; writeReport()
      let bad = EmbeddedCommandExecutor(resourceURL: resourceURL)
      let cancelledID = UUID()
      let infinite = Task { try await bad.run(.init(id:cancelledID,argv:["python","-c","print('started',flush=True)\nwhile True: pass"]),workspaceURL:root,onOutput:{_,text in
        if text.contains("started") { Task { try? await Task.sleep(for:.milliseconds(100)); bad.cancel() } }
      }) {_,_,_ in "{}"} }
      do { _ = try await infinite.value; report["cancel"] = false }
      catch is CancellationError { report["cancel"] = true }
      writeReport()
      do {
        _ = try await EmbeddedCommandExecutor(resourceURL: resourceURL).run(.init(id:cancelledID,argv:["python","-c","print('started',flush=True)\nwhile True: pass"]),workspaceURL:root) { _,_,_ in "{}" }
        report["interruptedReplayRejected"] = false
      } catch { report["interruptedReplayRejected"] = error.localizedDescription.contains("will not be replayed automatically") }
      let conflict = EmbeddedCommandExecutor(resourceURL: resourceURL)
      try Data("original".utf8).write(to:root.appendingPathComponent("shared.txt"))
      do {
        _ = try await conflict.run(.init(id:UUID(),argv:["python","-c","from pathlib import Path\nPath('shared.txt').write_text('worker edit')\nprint('change-now',flush=True)"]),workspaceURL:root,onOutput:{_,text in
          if text.contains("change-now") { try? Data("native edit".utf8).write(to:root.appendingPathComponent("shared.txt")) }
        }) {_,_,_ in "{}"}
        report["conflictPreserved"] = false
      } catch { report["conflictPreserved"] = (try? String(contentsOf:root.appendingPathComponent("shared.txt"),encoding:.utf8)) == "native edit" }
      var budgets = EmbeddedExecutionLimits(); budgets.previewBytes = 16
      let verbose = try await EmbeddedCommandExecutor(resourceURL: resourceURL, limits:budgets).run(.init(id:UUID(),argv:["python","-c","print('x'*1000)"]),workspaceURL:root) {_,_,_ in "{}"}
      let fullOutput = try Data(contentsOf:root.appendingPathComponent(verbose.stdoutPath))
      report["fullOutputSaved"] = verbose.outputPreviewLimited && verbose.stdout.utf8.count == 16 && fullOutput.count == 1001
      try Data("import unittest\nclass Checks(unittest.TestCase):\n    def test_math(self): self.assertEqual(sum([1,2,3]),6)\n".utf8).write(to:root.appendingPathComponent("test_math.py"))
      let tests = try await EmbeddedCommandExecutor(resourceURL: resourceURL).run(.init(id:UUID(),argv:["python","-m","unittest","discover","-s","."]),workspaceURL:root) {_,_,_ in "{}"}
      report["pythonUnitTests"] = tests.exitCode == 0 && tests.stderr.contains("Ran 1 test")
      writeReport()
      var inlineContents = ""
      let inline = try await EmbeddedCommandExecutor(resourceURL: resourceURL).run(.init(id:UUID(),argv:["python","-c","from pathlib import Path\nPath('draft.html').write_text('<p>fresh virtual contents</p>')\nprint(await woven_mcp('woven_notes_set_html', {'noteID':'example', 'html':Path('draft.html').read_text()}))"]),workspaceURL:root) { name, argumentsJSON, _ in
        let input = try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]
        if name == "woven_notes_set_html" { inlineContents = input?["html"] as? String ?? "" }
        return "{\"success\":true}"
      }
      report["virtualMCPFile"] = inline.exitCode == 0 && inlineContents == "<p>fresh virtual contents</p>"
      let imports: EmbeddedCommandExecutor.FileImports = { _, _, json in
        let object = try JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any]
        if let response = object?["structuredContent"] as? [String:Any], let result = response["result"] as? [String:Any], let path = result["workspacePath"] as? String { return [path] }
        return []
      }
      let imported = try await EmbeddedCommandExecutor(resourceURL: resourceURL).run(.init(id:UUID(),argv:["python","-c","from pathlib import Path\nPath('draft.html').write_text('preserved virtual change')\nresponse = await woven_mcp('woven_library_read', {'id':'artifact'})\nprint(Path(response['structuredContent']['result']['workspacePath']).read_text())"]),workspaceURL:root,importFiles:imports) { _,_,_ in
        let file = root.appendingPathComponent("library/example/data.txt")
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("imported artifact".utf8).write(to:file)
        return "{\"content\":[],\"structuredContent\":{\"success\":true,\"result\":{\"workspacePath\":\"library/example/data.txt\"}}}"
      }
      let preservedDraft = try String(contentsOf:root.appendingPathComponent("draft.html"),encoding:.utf8)
      report["libraryIntoPython"] = imported.exitCode == 0 && imported.stdout.contains("imported artifact") && preservedDraft == "preserved virtual change"
      do {
        _ = try await EmbeddedCommandExecutor(resourceURL: resourceURL).run(.init(id:UUID(),argv:["python","-c","from pathlib import Path\nPath('draft.html').write_text('must not commit')\nawait woven_mcp('woven_library_read', {'id':'second-artifact'})"]),workspaceURL:root,importFiles:imports) { _,_,_ in
          try Data("external concurrent edit".utf8).write(to:root.appendingPathComponent("shared.txt"))
          try Data("second import".utf8).write(to:root.appendingPathComponent("library/example/second.txt"))
          return "{\"content\":[],\"structuredContent\":{\"success\":true,\"result\":{\"workspacePath\":\"library/example/second.txt\"}}}"
        }
        report["importKeepsConflict"] = false
      } catch {
        let draft = try String(contentsOf:root.appendingPathComponent("draft.html"),encoding:.utf8)
        let shared = try String(contentsOf:root.appendingPathComponent("shared.txt"),encoding:.utf8)
        report["importKeepsConflict"] = draft == "preserved virtual change" && shared == "external concurrent edit"
      }
      writeReport()
      let link = EmbeddedCommandExecutor(resourceURL: resourceURL)
      do {
        _ = try await link.run(.init(id:UUID(),argv:["python","-c","import os; os.symlink('/lib','escape')"]),workspaceURL:root) {_,_,_ in "{}"}
        report["symlinkRejected"] = false
      } catch { report["symlinkRejected"] = true }
      report["status"] = "passed"; writeReport()
    } catch { report["status"] = "failed"; report["error"] = String(describing:error); writeReport() }
  }
}
