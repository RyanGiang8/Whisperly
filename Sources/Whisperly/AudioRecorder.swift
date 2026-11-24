import AVFoundation

/// Records microphone audio and returns 16 kHz mono Float32 samples,
/// the format Whisper expects.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    private(set) var isRecording = false

    /// Called on the main thread with the RMS level (0…~0.5) of each audio chunk.
    var onLevel: ((Float) -> Void)?

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func start() throws {
        guard !isRecording else { return }
        samples.removeAll()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "Whisperly", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000,
                                         channels: 1,
                                         interleaved: false)!
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = 16000.0 / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            var fed = false
            converter.convert(to: out, error: nil) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if out.frameLength > 0, let data = out.floatChannelData {
                let chunk = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
                self.lock.lock()
                self.samples.append(contentsOf: chunk)
                self.lock.unlock()

                var sum: Float = 0
                for s in chunk { sum += s * s }
                let rms = (chunk.count > 0) ? sqrt(sum / Float(chunk.count)) : 0
                DispatchQueue.main.async { self.onLevel?(rms) }
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Copy of everything captured so far — used for live preview transcription.
    func snapshotSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Stops recording and returns the captured 16 kHz mono samples.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        lock.lock()
        let result = samples
        samples.removeAll()
        lock.unlock()
        return result
    }
}
