import Darwin
import Foundation
import XCTest
@testable import WovenMatterDashboardStore
import WovenMatterCore

@MainActor
extension CompanionTransportTests {
  func testRealSupervisorDispatchHeartbeatEOFAndForcedReap() async throws {
    let fixture = try await SupervisorFixture.build()
    defer { fixture.remove() }

    let ordinary = try fixture.launch(arguments: ["--ordinary-app-argument"])
    try await waitForFixture { !ordinary.process.isRunning }
    XCTAssertEqual(ordinary.process.terminationStatus, 73, "Normal launches must bypass helper mode")
    let invalid = try fixture.launch(arguments: [CompanionServeSupervisor.argument])
    try await waitForFixture { !invalid.process.isRunning }
    XCTAssertEqual(invalid.process.terminationStatus, 64)
    let natural = try fixture.launch(arguments: [CompanionServeSupervisor.argument, fixture.executable.path, "--fixture-exit", "42"])
    try await waitForFixture { !natural.process.isRunning }
    XCTAssertEqual(natural.process.terminationStatus, 42, "Child exit must propagate while the parent pipe is open")

    for resistant in [false, true] {
      let pidFile = fixture.directory.appendingPathComponent("child-\(resistant).pid")
      let report = fixture.directory.appendingPathComponent("reaped-\(resistant).txt")
      let child = try fixture.launch(arguments: [CompanionServeSupervisor.argument, fixture.executable.path,
        resistant ? "--fixture-resistant-child" : "--fixture-cooperative-child", pidFile.path],
        childPIDFile: pidFile, reapReport: report)
      defer { child.cleanup(childPIDFile: pidFile) }
      try await waitForFixture { FileManager.default.fileExists(atPath: pidFile.path) }
      let pid = try fixturePID(at: pidFile)
      XCTAssertTrue(child.process.isRunning)
      XCTAssertEqual(kill(pid, 0), 0)
      let began = ProcessInfo.processInfo.systemUptime
      try child.heartbeat.fileHandleForWriting.close()
      try await waitForFixture { !child.process.isRunning }
      XCTAssertEqual(child.process.terminationStatus, 0)
      XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 3)
      if resistant { XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - began, 0.9) }
      XCTAssertEqual(try String(contentsOf: report, encoding: .utf8), "-1:\(ECHILD)", "Production supervisor must reap its child before exiting")
      XCTAssertEqual(kill(pid, 0), -1)
      XCTAssertEqual(errno, ESRCH)
    }
  }

  func testRealSupervisorStopsAfterAbruptParentDeathWithoutCleanupHandlers() async throws {
    let fixture = try await SupervisorFixture.build()
    defer { fixture.remove() }
    let helperPIDFile = fixture.directory.appendingPathComponent("helper.pid")
    let childPIDFile = fixture.directory.appendingPathComponent("child.pid")
    let report = fixture.directory.appendingPathComponent("reaped.txt")
    let parent = try fixture.launch(arguments: ["--fixture-crashing-parent", helperPIDFile.path, childPIDFile.path],
                                    childPIDFile: childPIDFile, reapReport: report)
    defer { parent.cleanup(childPIDFile: childPIDFile) }
    try await waitForFixture { !parent.process.isRunning }
    XCTAssertEqual(parent.process.terminationReason, .uncaughtSignal)
    XCTAssertEqual(parent.process.terminationStatus, SIGKILL)
    let pid = try fixturePID(at: childPIDFile)
    let helperPID = try fixturePID(at: helperPIDFile)
    try await waitForFixture { FileManager.default.fileExists(atPath: report.path) }
    XCTAssertEqual(try String(contentsOf: report, encoding: .utf8), "-1:\(ECHILD)")
    try await waitForFixture { kill(pid, 0) == -1 && errno == ESRCH }
    try await waitForFixture { kill(helperPID, 0) == -1 && errno == ESRCH }
  }

  func testPreferredServePortIsReusedAfterOwnedChildFinishesStopping() async throws {
    let fixture = ServeLifecycleFixture(cleanupDelay: 0.2)
    let serve = fixture.makeServe()
    defer { serve.stop() }
    let first = try await serve.start(loopbackPort: 50001, preferredHTTPSPort: 10000)
    XCTAssertEqual(first.absoluteString, "https://fixture.test.ts.net:10000/wovenmatter")
    let old = try XCTUnwrap(fixture.children.first)
    serve.stop()
    XCTAssertTrue(old.isRunning, "Fixture must reproduce asynchronous foreground route cleanup")
    let restarted = try await serve.start(loopbackPort: 50002, preferredHTTPSPort: 10000)
    XCTAssertEqual(restarted, first)
    XCTAssertFalse(old.isRunning)
    XCTAssertEqual(fixture.children.count, 2)
    XCTAssertEqual(old.terminationCalls, 1)
    XCTAssertEqual(fixture.launchArguments.map { $0[1] }, ["--https=10000", "--https=10000"])
    XCTAssertFalse(fixture.probedWhileStopping, "Do not mistake our still-draining route for an unrelated occupied port")
    XCTAssertEqual(fixture.existingPorts, [443, 8443])
    XCTAssertTrue(fixture.probeArguments.allSatisfy { $0 == ["status", "--json"] || $0 == ["serve", "status", "--json"] })
  }

  func testOccupiedPreferredServePortFailsWithoutChangingExistingRoutes() async throws {
    let fixture = ServeLifecycleFixture(existingPorts: [443, 8443, 10000])
    let serve = fixture.makeServe()
    do {
      _ = try await serve.start(loopbackPort: 50001, preferredHTTPSPort: 10000)
      XCTFail("A paired endpoint must not silently change to a different port")
    } catch {
      XCTAssertEqual((error as? CompanionAPIError)?.code, "tailscale_unavailable")
    }
    XCTAssertFalse(serve.isRunning)
    XCTAssertTrue(fixture.children.isEmpty)
    XCTAssertTrue(fixture.launchArguments.isEmpty)
    XCTAssertEqual(fixture.existingPorts, [443, 8443, 10000])
    XCTAssertEqual(fixture.probeArguments, [["status", "--json"], ["serve", "status", "--json"]])
  }

  func testOwnedServeCleanupWaitIsBoundedAndCanBeCancelled() async throws {
    let fixture = ServeLifecycleFixture(cleanupDelay: 60)
    let serve = fixture.makeServe()
    defer { fixture.children.forEach { $0.forceStopped = true }; serve.stop() }
    _ = try await serve.start(loopbackPort: 50001, preferredHTTPSPort: 10000)
    serve.stop()
    let began = ProcessInfo.processInfo.systemUptime
    do { _ = try await serve.start(loopbackPort: 50002, preferredHTTPSPort: 10000); XCTFail("Hung cleanup should be bounded") }
    catch { XCTAssertEqual((error as? CompanionAPIError)?.code, "tailscale_unavailable") }
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 4)
    let pending = Task { try await serve.start(loopbackPort: 50003, preferredHTTPSPort: 10000) }
    await Task.yield()
    pending.cancel()
    do { _ = try await pending.value; XCTFail("Cancelled restart should not launch") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.children.count, 1)
    XCTAssertFalse(fixture.probedWhileStopping)
  }
}

@MainActor
private func waitForFixture(timeout: TimeInterval = 5, _ condition: () throws -> Bool) async throws {
  let deadline = ProcessInfo.processInfo.systemUptime + timeout
  while try !condition() {
    if ProcessInfo.processInfo.systemUptime >= deadline { throw FixtureFailure.timeout }
    try await Task.sleep(for: .milliseconds(10))
  }
}

private enum FixtureFailure: Error { case timeout, invalidPID }
private func fixturePID(at url: URL) throws -> Int32 {
  guard let pid = Int32(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
    throw FixtureFailure.invalidPID
  }
  return pid
}

@MainActor
private struct SupervisorFixture {
  let directory: URL
  var executable: URL { directory.appendingPathComponent("CompanionServeSupervisorFixture") }
  static func build() async throws -> Self {
    let source = URL(fileURLWithPath: #filePath)
    let repository = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("woven-supervisor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = Self(directory: directory)
    do {
      _ = try await CompanionProcessProbe().run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["swiftc", "-parse-as-library",
        repository.appendingPathComponent("app/Sources/WovenMatterDashboardStore/CompanionServeSupervisor.swift").path,
        repository.appendingPathComponent("scripts/test-support/CompanionServeSupervisorFixture.swift").path,
        "-module-cache-path", directory.appendingPathComponent("ModuleCache").path, "-o", fixture.executable.path], timeout: 30)
      return fixture
    } catch { fixture.remove(); throw error }
  }
  func launch(arguments: [String], childPIDFile: URL? = nil, reapReport: URL? = nil) throws -> SupervisorFixtureProcess {
    let process = Process(), heartbeat = Pipe()
    _ = fcntl(heartbeat.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = heartbeat
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment["WOVEN_FIXTURE_CHILD_PID_FILE"] = childPIDFile?.path
    environment["WOVEN_FIXTURE_REAP_REPORT"] = reapReport?.path
    process.environment = environment
    try process.run()
    try heartbeat.fileHandleForReading.close()
    return SupervisorFixtureProcess(process: process, heartbeat: heartbeat)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private struct SupervisorFixtureProcess {
  let process: Process
  let heartbeat: Pipe
  func cleanup(childPIDFile: URL) {
    try? heartbeat.fileHandleForWriting.close()
    // Only fixture-owned IDs are eligible for emergency cleanup if an assertion fails.
    if let pid = try? fixturePID(at: childPIDFile), kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
    if process.isRunning { process.terminate() }
  }
}

@MainActor
private final class ServeLifecycleFixture {
  let existingPorts: Set<Int>
  let cleanupDelay: TimeInterval
  var children: [DelayedServingProcess] = []
  var launchArguments: [[String]] = []
  var probeArguments: [[String]] = []
  var probedWhileStopping = false
  init(existingPorts: Set<Int> = [443, 8443], cleanupDelay: TimeInterval = 0) {
    self.existingPorts = existingPorts; self.cleanupDelay = cleanupDelay
  }
  func makeServe() -> CompanionTailscaleServe {
    CompanionTailscaleServe(executable: URL(fileURLWithPath: "/fixture/tailscale"),
      probe: { _, arguments in try await self.probe(arguments) },
      launch: { _, arguments in
        self.launchArguments.append(arguments)
        let child = DelayedServingProcess(cleanupDelay: self.cleanupDelay,
          port: Int(arguments[1].dropFirst("--https=".count))!, target: arguments[3])
        self.children.append(child)
        return child
      })
  }
  func probe(_ arguments: [String]) throws -> Data {
    probeArguments.append(arguments)
    probedWhileStopping = probedWhileStopping || children.contains { $0.isRunning && $0.terminationCalls > 0 }
    if arguments == ["status", "--json"] {
      return Data(#"{"BackendState":"Running","Self":{"DNSName":"fixture.test.ts.net."}}"#.utf8)
    }
    let tcp = Dictionary(uniqueKeysWithValues: existingPorts.map { (String($0), ["HTTPS": true]) })
    var foreground: [String: Any] = [:]
    for (index, child) in children.enumerated() where child.isRunning {
      foreground[String(index)] = ["TCP": [String(child.port): ["HTTPS": true]],
        "Web": ["fixture.test.ts.net:\(child.port)": ["Handlers": ["/wovenmatter": ["Proxy": child.target]]]]]
    }
    return try JSONSerialization.data(withJSONObject: ["TCP": tcp, "Foreground": foreground], options: .sortedKeys)
  }
}

@MainActor
private final class DelayedServingProcess: CompanionServingProcess {
  let cleanupDelay: TimeInterval
  let port: Int
  let target: String
  var stoppedAt: TimeInterval?
  var forceStopped = false
  var terminationCalls = 0
  init(cleanupDelay: TimeInterval, port: Int, target: String) {
    self.cleanupDelay = cleanupDelay; self.port = port; self.target = target
  }
  var isRunning: Bool { !forceStopped && stoppedAt.map { ProcessInfo.processInfo.systemUptime - $0 < cleanupDelay } ?? !forceStopped }
  func terminate() { terminationCalls += 1; stoppedAt = ProcessInfo.processInfo.systemUptime }
}
