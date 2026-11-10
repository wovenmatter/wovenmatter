// The Woven VM is macOS only.
#if os(macOS)
import Compression
import Darwin
import Foundation
import Testing
@testable import WovenMatterClient

private func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: "/private/tmp/wovenvm-tests-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A minimal QCOW2 v3 image with 4 KiB clusters: cluster 0 stored raw,
/// cluster 1 zlib-compressed, cluster 2 flagged as zeros, cluster 3
/// unallocated, cluster 4 a partial tail.
private func makeQCOW2(at url: URL, raw: [UInt8], compressedPayload: [UInt8], tail: [UInt8]) throws {
    let clusterBits = 12, cluster = 1 << clusterBits
    let virtualSize = UInt64(cluster * 4 + tail.count)
    var file = [UInt8](repeating: 0, count: cluster * 6)
    func put64(_ value: UInt64, at offset: Int) { for i in 0..<8 { file[offset + i] = UInt8(truncatingIfNeeded: value >> (56 - 8 * UInt64(i))) } }
    func put32(_ value: UInt32, at offset: Int) { for i in 0..<4 { file[offset + i] = UInt8(truncatingIfNeeded: value >> (24 - 8 * UInt32(i))) } }
    put32(0x5146_49fb, at: 0); put32(3, at: 4); put32(UInt32(clusterBits), at: 20); put64(virtualSize, at: 24)
    put32(1, at: 36); put64(UInt64(cluster), at: 40); put32(4, at: 96); put32(104, at: 100)
    // L1 at cluster 1 -> L2 at cluster 2; raw data at cluster 3; tail at cluster 4;
    // compressed bytes at cluster 5.
    put64(UInt64(cluster * 2) | (1 << 63), at: cluster)
    let l2 = cluster * 2
    put64(UInt64(cluster * 3) | (1 << 63), at: l2)
    var compressed = [UInt8](repeating: 0, count: cluster * 2)
    let length = compression_encode_buffer(&compressed, compressed.count, compressedPayload, compressedPayload.count, nil, COMPRESSION_ZLIB)
    #expect(length > 0 && length < cluster)
    let offset = UInt64(cluster * 5), x = UInt64(62 - (clusterBits - 8))
    let sectors = (UInt64(length) + 511) / 512 - 1
    put64(offset | (sectors << x) | (1 << 62), at: l2 + 8)
    put64(1, at: l2 + 16)
    put64(UInt64(cluster * 4) | (1 << 63), at: l2 + 32)
    file.replaceSubrange(cluster * 3..<cluster * 4, with: raw)
    file.replaceSubrange(cluster * 4..<cluster * 4 + tail.count, with: tail)
    file.replaceSubrange(cluster * 5..<cluster * 5 + length, with: compressed.prefix(length))
    try Data(file).write(to: url)
}

struct WovenVMTests {
    @Test func qcow2ConversionHandlesRawCompressedZeroAndUnallocatedClusters() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = (0..<4096).map { UInt8(truncatingIfNeeded: $0 * 7 + 1) }
        let payload = (0..<4096).map { UInt8(truncatingIfNeeded: $0 / 16) }
        let tail = [UInt8](repeating: 0xab, count: 1000)
        let source = directory.appending(path: "image.qcow2"), output = directory.appending(path: "disk.img")
        try makeQCOW2(at: source, raw: raw, compressedPayload: payload, tail: tail)
        #expect(try QCOW2Image.readHeader(open(source.path, O_RDONLY)).virtualSize == 4 * 4096 + 1000)
        var reported: [Double] = []
        try QCOW2Image.convert(source, to: output) { reported.append($0) }
        let bytes = [UInt8](try Data(contentsOf: output))
        #expect(bytes.count == 4 * 4096 + 1000)
        #expect(Array(bytes[0..<4096]) == raw)
        #expect(Array(bytes[4096..<8192]) == payload)
        #expect(bytes[8192..<16_384].allSatisfy { $0 == 0 })
        #expect(Array(bytes[16_384...]) == tail)
        #expect(reported.last == 1)
        // A second conversion never overwrites an existing output.
        #expect(throws: (any Error).self) { try QCOW2Image.convert(source, to: output) }
    }

    @Test func qcow2RejectsUnsupportedImagesAndLeavesNoOutput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "image.qcow2"), output = directory.appending(path: "disk.img")
        try makeQCOW2(at: source, raw: .init(repeating: 1, count: 4096), compressedPayload: .init(repeating: 2, count: 4096), tail: [3])
        var data = [UInt8](try Data(contentsOf: source))
        data[15] = 0x70 // a backing file offset
        try Data(data).write(to: source)
        #expect(throws: WovenVMError.self) { try QCOW2Image.convert(source, to: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try Data("not an image at all, just text".utf8).write(to: source)
        #expect(throws: WovenVMError.self) { try QCOW2Image.convert(source, to: output) }
    }

    @Test func forwardRequestsNameExactlyOneValidTarget() throws {
        #expect(try WovenVMForwardRequest(container: "bot-1_a.b", port: 3000).validated().port == 3000)
        #expect(try WovenVMForwardRequest(address: "127.0.0.1", port: 80, hostPort: 18_080).validated().hostPort == 18_080)
        #expect(try WovenVMForwardRequest(address: "fd00::1", port: 80).validated().address == "fd00::1")
        for invalid in [WovenVMForwardRequest(container: "a b", port: 80), WovenVMForwardRequest(container: "x\n", port: 80),
                        WovenVMForwardRequest(port: 80), WovenVMForwardRequest(container: "a", address: "0.0.0.0", port: 80),
                        WovenVMForwardRequest(address: "not-an-ip", port: 80), WovenVMForwardRequest(container: "a", port: 0),
                        WovenVMForwardRequest(container: "a", port: 80, hostPort: 70_000)] {
            #expect(throws: WovenVMError.self) { try invalid.validated() }
        }
    }

    @Test func socketsMoveToAShortPrivatePathWhenTheRootIsTooLong() {
        let short = WovenVMPaths(root: URL(fileURLWithPath: "/private/var/home/Library/Application Support/Woven Matter/WovenVM"))
        #expect(short.engineSocket.path == "/private/var/home/Library/Application Support/Woven Matter/WovenVM/docker.sock")
        let long = WovenVMPaths(root: URL(fileURLWithPath: "/private/var/home/Library/Application Support/Woven Matter Dev/"
            + String(repeating: "i", count: 64) + "/snapshot/WovenVM"))
        #expect(long.socketDirectory.path.hasPrefix("/private/tmp/wovenmatter-vm-\(getuid())-"))
        #expect(long.controlSocket.path.utf8.count < 104)
        #expect(long.disk.path.hasSuffix("/snapshot/WovenVM/disk.img"))
    }

    @Test func theSocketDirectoryMustBeAPrivateDirectoryOfThisUser() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fresh = base.appending(path: "fresh", directoryHint: .isDirectory)
        #expect(throws: WovenVMError.self) { try WovenVMPaths.preparePrivateDirectory(fresh, create: false) }
        try WovenVMPaths.preparePrivateDirectory(fresh)
        var info = stat()
        #expect(lstat(fresh.path, &info) == 0 && info.st_mode & 0o777 == 0o700 && info.st_uid == getuid())
        // An existing directory of this user is tightened; anything else is refused.
        let open = base.appending(path: "open", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o777])
        chmod(open.path, 0o777)
        try WovenVMPaths.preparePrivateDirectory(open)
        #expect(lstat(open.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        let link = base.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fresh)
        #expect(throws: WovenVMError.self) { try WovenVMPaths.preparePrivateDirectory(link) }
        let file = base.appending(path: "file")
        try Data().write(to: file)
        #expect(throws: WovenVMError.self) { try WovenVMPaths.preparePrivateDirectory(file) }
        // A directory another user owns: /private/tmp itself is root's.
        #expect(throws: WovenVMError.self) { try WovenVMPaths.preparePrivateDirectory(URL(fileURLWithPath: "/private/tmp"), create: false) }
    }

    @Test func launchAgentRestartsOnlyUnexpectedExits() throws {
        let plist = WovenVMLaunchAgent.propertyList(label: "wovenmatter.desktop.vm",
            helper: URL(fileURLWithPath: "/Applications/Woven Matter.app/Contents/Helpers/WovenMatterVMHelper"),
            root: URL(fileURLWithPath: "/tmp/root"))
        #expect(plist["Label"] as? String == "wovenmatter.desktop.vm")
        #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["ProgramArguments"] as? [String] == ["/Applications/Woven Matter.app/Contents/Helpers/WovenMatterVMHelper", "--root", "/tmp/root"])
        #expect(WovenVMLaunchAgent.label(bundleIdentifier: "wovenmatter.desktop.dev") == "wovenmatter.desktop.dev.vm")
    }

    @Test func balloonFollowsDemandWithHeadroomAndHysteresis() {
        let gib: UInt64 = 1 << 30, mib: UInt64 = 1 << 20
        // An idle 8 GiB VM using 700 MiB keeps 700 MiB plus 2 GiB headroom.
        let idle = WovenVMBalloonPolicy.desiredTarget(ceiling: 8 * gib, booted: 8 * gib, current: 8 * gib,
                                                      guestTotal: 7992 * mib, guestAvailable: 7292 * mib)
        #expect(idle == 700 * mib + 2 * gib)
        // Ballooned pages count as used in the guest; they are not demand.
        let inflated = WovenVMBalloonPolicy.desiredTarget(ceiling: 8 * gib, booted: 8 * gib, current: idle,
                                                          guestTotal: 7992 * mib,
                                                          guestAvailable: 7292 * mib - (8 * gib - idle))
        #expect(inflated == idle)
        // Pressure inside the balloon opens it fully.
        #expect(WovenVMBalloonPolicy.desiredTarget(ceiling: 8 * gib, booted: 8 * gib, current: 3 * gib,
                                                   guestTotal: 7992 * mib, guestAvailable: 900 * mib) == 8 * gib)
        // A bot allocating 4 GiB raises it; never above the pool, never below the floor.
        #expect(WovenVMBalloonPolicy.desiredTarget(ceiling: 8 * gib, booted: 8 * gib, current: 8 * gib,
                                                   guestTotal: 8 * gib, guestAvailable: gib / 2) == 8 * gib)
        #expect(WovenVMBalloonPolicy.desiredTarget(ceiling: gib, booted: gib, current: gib,
                                                   guestTotal: gib, guestAvailable: gib) == gib)
        // Raise at once; lower only after demand stayed lower for 30 s.
        let now = Date()
        #expect(WovenVMBalloonPolicy.next(current: 3 * gib, desired: 5 * gib, lowerSince: now, now: now) == (5 * gib, nil))
        let pending = WovenVMBalloonPolicy.next(current: 5 * gib, desired: 3 * gib, lowerSince: nil, now: now)
        #expect(pending.target == 5 * gib && pending.lowerSince == now)
        #expect(WovenVMBalloonPolicy.next(current: 5 * gib, desired: 3 * gib, lowerSince: now, now: now + 31).target == 3 * gib)
        #expect(WovenVMBalloonPolicy.next(current: 5 * gib, desired: 5 * gib - 100 * mib, lowerSince: now, now: now + 60).target == 5 * gib)
        #expect(WovenVMBalloonPolicy.ceiling(bootedBytes: 8 * gib, requestedBytes: 4 * gib) == 4 * gib)
        #expect(WovenVMBalloonPolicy.ceiling(bootedBytes: 8 * gib, requestedBytes: 16 * gib) == 8 * gib)
    }

    @Test func sizingFollowsTheResourceRules() throws {
        let gib: UInt64 = 1 << 30
        #expect(WovenVMSizing.memoryBytes(requested: nil, physical: 16 * gib + 123, maximumAllowed: 64 * gib) == 16 * gib)
        #expect(WovenVMSizing.memoryBytes(requested: 8 * gib, physical: 16 * gib, maximumAllowed: 64 * gib) == 8 * gib)
        #expect(WovenVMSizing.memoryBytes(requested: 100, physical: 16 * gib, maximumAllowed: 64 * gib) == gib)
        try WovenVMSizing.validate(.init(memoryBytes: nil, diskBytes: nil), physicalMemory: 16 * gib, diskTotal: 500 * gib)
        try WovenVMSizing.validate(.init(), physicalMemory: 16 * gib, diskTotal: 500 * gib)
        #expect(throws: WovenVMError.self) { try WovenVMSizing.validate(.init(memoryBytes: 32 * gib), physicalMemory: 16 * gib, diskTotal: 500 * gib) }
        #expect(throws: WovenVMError.self) { try WovenVMSizing.validate(.init(diskBytes: gib), physicalMemory: 16 * gib, diskTotal: 500 * gib) }
        #expect(throws: WovenVMError.self) { try WovenVMSizing.validate(.init(diskBytes: 600 * gib), physicalMemory: 16 * gib, diskTotal: 500 * gib) }
    }

    @Test func controlHTTPParsesCompleteRequestsOnly() throws {
        let head = "PUT /v1/resources HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n"
        #expect(try WovenVMControlHTTP.parseRequest(Data(head.utf8)) == nil)
        let request = try WovenVMControlHTTP.parseRequest(Data((head + "{\"a\"}").utf8))
        #expect(request == .init(method: "PUT", path: "/v1/resources", body: Data("{\"a\"}".utf8)))
        #expect(throws: WovenVMError.self) {
            try WovenVMControlHTTP.parseRequest(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8))
        }
        #expect(throws: WovenVMError.self) {
            try WovenVMControlHTTP.parseRequest(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        }
        let response = WovenVMControlHTTP.response(status: 201, body: Data("{}".utf8))
        let parsed = try WovenVMControlHTTP.parseResponse(response)
        #expect(parsed.status == 201 && parsed.body == Data("{}".utf8))
    }

    /// The bundled guest files are what the record says, and the seed carries
    /// them without any login credential.
    @Test func guestSeedCarriesThePinnedFilesAndNoCredentials() throws {
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "VMHelper")
        let resources = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: resources) }
        try FileManager.default.copyItem(at: helper.appending(path: "guest-version.json"), to: resources.appending(path: "guest-version.json"))
        for entry in WovenVMGuestFiles.layout {
            try FileManager.default.copyItem(at: helper.appending(path: "Guest/" + entry.name), to: resources.appending(path: entry.name))
        }
        let version = try WovenVMGuestFiles.loadVersion(resources: resources)
        #expect(version.docker.engineVersion == version.docker.dockerCE.split(separator: ":")[1].split(separator: "-")[0].description)
        #expect(version.image.url.absoluteString.contains("/release-\(version.image.serial)/"))
        let files = try WovenVMGuestFiles.files(resources: resources, version: version)
        #expect(files.count == WovenVMGuestFiles.layout.count + 1)
        #expect(String(decoding: files[WovenVMGuestFiles.versionsPath]!, as: UTF8.self).contains("DOCKER_CE_VERSION='\(version.docker.dockerCE)'"))
        let userData = WovenVMGuestFiles.userData(files: files, diskCapBytes: 50 << 30)
        #expect(userData.hasPrefix("#cloud-config\n"))
        #expect(userData.contains("content: \"53687091200\""))
        #expect(userData.contains("ssh_pwauth: false") && userData.contains("users: []"))
        for word in ["ssh_authorized_keys", "passwd", "chpasswd"] { #expect(!userData.contains(word)) }
        for entry in WovenVMGuestFiles.layout { #expect(userData.contains("- path: \(entry.path)")) }

        // A tampered signing key is refused.
        try Data("tampered".utf8).write(to: resources.appending(path: "docker-archive-keyring.asc"))
        #expect(throws: WovenVMError.self) { try WovenVMGuestFiles.files(resources: resources, version: version) }
    }

    @Test func controllerInstallsTheAgentOnceAndMapsHelperErrors() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "WovenVM")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = WovenVMPaths(root: root)
        let server = try FakeControlServer(path: paths.controlSocket.path) { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/status"):
                return (200, try JSONEncoder().encode(WovenVMStatus(phase: .provisioning, detail: "Installing Docker Engine",
                                                                    engineSocket: paths.engineSocket.path)))
            case ("POST", "/v1/update"):
                return (409, try JSONEncoder().encode(WovenVMControlHTTP.ErrorBody(error: "The VM can update only when it is ready.")))
            default:
                return (404, Data())
            }
        }
        defer { server.stop() }
        let calls = CallLog()
        let plist = directory.appending(path: "LaunchAgents/test.vm.plist")
        let controller = WovenVMController(root: root, label: "test.vm", helper: URL(fileURLWithPath: "/bin/helper"),
                                           launchAgentPlist: plist) { arguments in
            calls.append(arguments)
            return arguments.first == "print" ? (calls.count > 2 ? 0 : 113) : 0
        }
        let status = try await controller.ensureRunning()
        #expect(status.phase == .provisioning && status.detail == "Installing Docker Engine")
        #expect(calls.values.map { $0[0] } == ["print", "bootstrap", "kickstart"])
        let written = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        #expect(written?["Label"] as? String == "test.vm")
        #expect(try FileManager.default.attributesOfItem(atPath: plist.path)[.posixPermissions] as? Int == 0o600)
        // Unchanged plist and a loaded job: only a kickstart, never a reload.
        _ = try await controller.ensureRunning()
        #expect(calls.values.suffix(2).map { $0[0] } == ["print", "kickstart"])
        await #expect(throws: WovenVMError.unavailable("The VM can update only when it is ready.")) {
            try await controller.update()
        }
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func append(_ value: [String]) { lock.lock(); calls.append(value); lock.unlock() }
    var values: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
    var count: Int { values.count }
}

/// Serves canned replies on a Unix socket, one request per connection.
private final class FakeControlServer: @unchecked Sendable {
    private let fd: Int32
    private let path: String

    init(path: String, handler: @escaping @Sendable (WovenVMControlHTTP.Request) throws -> (Int, Data)) throws {
        self.path = path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        let listener = fd
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                var request: WovenVMControlHTTP.Request?
                while request == nil {
                    let count = read(client, &buffer, buffer.count)
                    guard count > 0 else { break }
                    data.append(buffer, count: count)
                    request = try? WovenVMControlHTTP.parseRequest(data)
                }
                if let request, let (status, body) = try? handler(request) {
                    let reply = WovenVMControlHTTP.response(status: status, body: body)
                    _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                }
                close(client)
            }
        }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }
}
#endif
