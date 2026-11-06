import Foundation
import Network

/// The Mac's end of `pi-bot-relay.mjs`: one child process whose stdio carries every
/// stream, a loopback listener for Pi Bot's port, and connections back to this Mac's
/// MCP endpoint. See that script for the frame format.
final class PiBotRelay: @unchecked Sendable {
    struct Hello: Equatable { let reversePort: Int? }

    private enum Frame {
        static let connect: UInt8 = 1, data: UInt8 = 2, close: UInt8 = 3, hello: UInt8 = 4, accept: UInt8 = 5
        static let header = 9
        static let maximumPayload = 16 * 1024 * 1024
    }

    private final class Stream {
        let connection: NWConnection
        var finishedReading = false
        var finishedWriting = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let lock = NSLock()
    private let network = DispatchQueue(label: "wovenmatter.pi-bot.relay.network")
    private let writer = DispatchQueue(label: "wovenmatter.pi-bot.relay.writer")
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let localPort: Int
    private let reverseTargetPort: Int?
    private var listener: NWListener?
    private var streams: [UInt32: Stream] = [:]
    private var nextStream: UInt32 = 1
    private var stopped = false
    private var reversePort: Int?
    private var greeted = false

    init(executable: URL, arguments: [String], errorLog: FileHandle?, localPort: Int, reverseTargetPort: Int?) {
        self.localPort = localPort
        self.reverseTargetPort = reverseTargetPort
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorLog ?? FileHandle.nullDevice
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [weak self] _ in self?.shutDown() }
        try process.run()
        let descriptor = output.fileHandleForReading.fileDescriptor
        Thread.detachNewThread { [self] in read(from: descriptor) }
        do {
            try listen()
        } catch {
            stop()
            throw error
        }
    }

    /// Set once the device is listening. Its reverse port may differ from the one asked
    /// for, because another program can hold it.
    var hello: Hello? {
        lock.withLock { greeted ? Hello(reversePort: reversePort) : nil }
    }

    func stop() {
        shutDown()
        if process.isRunning { process.terminate() }
    }

    private func shutDown() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let open = Array(streams.values)
        streams.removeAll()
        let current = listener
        listener = nil
        lock.unlock()
        current?.cancel()
        open.forEach { $0.connection.cancel() }
        try? input.fileHandleForWriting.close()
    }

    private func listen() throws {
        let parameters = NWParameters.tcp
        guard let port = NWEndpoint.Port(rawValue: UInt16(localPort)) else { throw PiBotHostError.invalidConnection }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accepted(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        lock.withLock { self.listener = listener }
        listener.start(queue: network)
    }

    private func accepted(_ connection: NWConnection) {
        lock.lock()
        guard !stopped else { lock.unlock(); connection.cancel(); return }
        let id = nextStream
        nextStream &+= 2
        let stream = Stream(connection)
        streams[id] = stream
        lock.unlock()
        write(Frame.connect, id)
        begin(stream, id: id)
    }

    private func begin(_ stream: Stream, id: UInt32) {
        stream.connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.discard(id)
            default: break
            }
        }
        stream.connection.start(queue: network)
        pump(stream, id: id)
    }

    /// The next read waits for this one to reach the child, so a slow device slows the sender.
    private func pump(_ stream: Stream, id: UInt32) {
        stream.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            let finished = complete || error != nil
            let next: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                if finished { self.finishedReading(id) } else { self.pump(stream, id: id) }
            }
            if let data, !data.isEmpty {
                self.write(Frame.data, id, data, then: next)
            } else {
                next()
            }
        }
    }

    private func finishedReading(_ id: UInt32) {
        lock.lock()
        guard let stream = streams[id] else { lock.unlock(); return }
        stream.finishedReading = true
        let done = stream.finishedWriting
        lock.unlock()
        write(Frame.close, id)
        if done { discard(id, cancel: true) }
    }

    private func discard(_ id: UInt32, cancel: Bool = false) {
        lock.lock()
        let stream = streams.removeValue(forKey: id)
        let announce = stream.map { !$0.finishedReading } ?? false
        lock.unlock()
        guard let stream else { return }
        if announce { write(Frame.close, id) }
        if cancel { stream.connection.cancel() }
    }

    private func write(_ type: UInt8, _ id: UInt32, _ payload: Data = Data(), then done: (@Sendable () -> Void)? = nil) {
        var frame = Data(capacity: Frame.header + payload.count)
        frame.append(type)
        withUnsafeBytes(of: id.bigEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        let handle = input.fileHandleForWriting
        writer.async {
            do { try handle.write(contentsOf: frame) } catch { /* The child exited; its handler cleans up. */ }
            done?()
        }
    }

    private func read(from descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var pending = Data()
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            pending.append(contentsOf: buffer[0..<count])
            var offset = pending.startIndex
            while pending.endIndex - offset >= Frame.header {
                let type = pending[offset]
                let id = Self.integer(pending, at: offset + 1)
                let length = Int(Self.integer(pending, at: offset + 5))
                guard length <= Frame.maximumPayload else { stop(); return }
                guard pending.endIndex - offset - Frame.header >= length else { break }
                let start = offset + Frame.header
                receive(type, id, Data(pending[start..<(start + length)]))
                offset = start + length
            }
            pending = offset == pending.endIndex ? Data() : Data(pending[offset...])
        }
        stop()
    }

    private static func integer(_ data: Data, at offset: Data.Index) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    private func receive(_ type: UInt8, _ id: UInt32, _ payload: Data) {
        switch type {
        case Frame.hello:
            let port = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["reversePort"] as? Int
            lock.withLock {
                greeted = true
                reversePort = port
            }
        case Frame.accept:
            acceptReverse(id)
        case Frame.data:
            deliver(id, payload)
        case Frame.close:
            remoteFinished(id)
        default:
            stop()
        }
    }

    private func acceptReverse(_ id: UInt32) {
        guard let reverseTargetPort, let port = NWEndpoint.Port(rawValue: UInt16(reverseTargetPort)) else {
            write(Frame.close, id)
            return
        }
        let stream = Stream(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        let open = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            streams[id] = stream
            return true
        }
        if open { begin(stream, id: id) }
    }

    /// Blocks the reader until the socket took the bytes, so a slow client slows the
    /// device. A client that stops reading loses only its own stream.
    private func deliver(_ id: UInt32, _ payload: Data) {
        guard let stream = lock.withLock({ streams[id] }) else { return }
        let sent = DispatchSemaphore(value: 0)
        stream.connection.send(content: payload, completion: .contentProcessed { _ in sent.signal() })
        if sent.wait(timeout: .now() + 30) == .timedOut {
            discard(id, cancel: true)
        }
    }

    private func remoteFinished(_ id: UInt32) {
        lock.lock()
        guard let stream = streams[id] else { lock.unlock(); return }
        stream.finishedWriting = true
        let done = stream.finishedReading
        if done { streams.removeValue(forKey: id) }
        lock.unlock()
        stream.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            if done { stream.connection.cancel() }
        })
    }
}
