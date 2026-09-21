import AVFoundation
import Foundation
import WovenMatterClient

@MainActor
protocol DictationCapturing {
    func start() throws -> AsyncThrowingStream<Data, any Error>
    func stop()
}

@MainActor
final class DictationAudioCapture: DictationCapturing {
    private let engine = AVAudioEngine()
    private var installed = false
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?

    func start() throws -> AsyncThrowingStream<Data, any Error> {
        let node = engine.inputNode
        let input = node.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw CaptureError.unavailable
        }
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        self.continuation = continuation
        let conversion = AudioConversion(converter: converter, output: output)
        node.installTap(onBus: 0, bufferSize: 2048, format: input) { buffer, _ in
            do {
                if let data = try conversion.convert(buffer) {
                    if case .dropped = continuation.yield(data) {
                        continuation.finish(throwing: GrokSpeechError.audioBacklog)
                    }
                }
            } catch { continuation.finish(throwing: error) }
        }
        installed = true
        do { try engine.start() } catch { stop(); throw CaptureError.unavailable }
        return stream
    }
    func stop() {
        engine.stop()
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
        continuation?.finish(); continuation = nil
    }
    enum CaptureError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The microphone is unavailable. Check your audio input in macOS Settings." }
    }
}

/// AVAudioEngine serializes this tap; conversion never touches observable UI.
private final class AudioConversion: @unchecked Sendable {
    let converter: AVAudioConverter
    let output: AVAudioFormat
    init(converter: AVAudioConverter, output: AVAudioFormat) { self.converter = converter; self.output = output }
    func convert(_ input: AVAudioPCMBuffer) throws -> Data? {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * output.sampleRate / input.format.sampleRate)) + 32
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, state in
            if delivered { state.pointee = .noDataNow; return nil }
            delivered = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard status != .error, let samples = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return nil }
        return Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }
}
