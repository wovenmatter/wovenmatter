import Foundation
import SQLite3
import WovenMatterClient

public enum HermesResultQueue {
  public static func read(home: String, offset: Int, limit: Int = 100) throws
    -> [HermesScheduledResult]
  {
    guard offset >= 0, (1...100).contains(limit) else {
      throw HermesGatewayError.message("Invalid result page.")
    }
    let path = URL(fileURLWithPath: home).appending(path: ".woven-matter/scheduled-results.sqlite")
      .path
    guard FileManager.default.fileExists(atPath: path) else { return [] }
    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database
    else {
      if let database { sqlite3_close(database) }
      throw HermesGatewayError.message("Hermes scheduled results could not be opened.")
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 5000)
    var query: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT job_id,run_id,output,saved_at FROM results ORDER BY saved_at,job_id,run_id LIMIT ? OFFSET ?",
        -1, &query, nil) == SQLITE_OK, let query
    else {
      throw HermesGatewayError.message("Hermes scheduled results could not be read.")
    }
    defer { sqlite3_finalize(query) }
    sqlite3_bind_int64(query, 1, Int64(limit))
    sqlite3_bind_int64(query, 2, Int64(offset))
    var results: [HermesScheduledResult] = []
    while true {
      let code = sqlite3_step(query)
      if code == SQLITE_DONE { return results }
      guard code == SQLITE_ROW, let job = sqlite3_column_text(query, 0),
        let run = sqlite3_column_text(query, 1), let output = sqlite3_column_text(query, 2)
      else {
        throw HermesGatewayError.message("Hermes returned an unreadable scheduled result.")
      }
      results.append(
        HermesScheduledResult(
          jobID: String(cString: job), runID: String(cString: run), output: String(cString: output),
          savedAt: sqlite3_column_double(query, 3)))
    }
  }
}
