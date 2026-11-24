import Foundation
import WhisperKit

/// Wraps WhisperKit. Model files are downloaded once to
/// ~/Documents/huggingface/ and all inference runs on-device.
actor Transcriber {
    static let availableModels = [
        "openai_whisper-tiny.en",
        "openai_whisper-base.en",
        "openai_whisper-small.en"
    ]
    static let defaultModel = "openai_whisper-small.en"

    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    /// Loads (downloading if needed) the given model. Safe to call repeatedly.
    func load(model: String) async throws {
        if loadedModel == model, whisperKit != nil { return }
        whisperKit = nil
        loadedModel = nil
        // Run on CPU+GPU, not the Neural Engine: on macOS 26 the ANE
        // recompiles the model (40 s+ each time), which made dictation
        // look frozen on "Transcribing…".
        let compute = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU,
            prefillCompute: .cpuOnly
        )
        // load: true — otherwise WhisperKit defers loading until the first
        // transcription, so "Ready" would show before the model is usable.
        let config = WhisperKitConfig(model: model,
                                      computeOptions: compute,
                                      verbose: false,
                                      load: true)
        let kit = try await WhisperKit(config)
        // Warm up with a second of silence so the first real dictation is fast.
        _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: 16000))
        whisperKit = kit
        loadedModel = model
    }

    var currentModel: String? { loadedModel }

    func transcribe(samples: [Float]) async throws -> String {
        guard let kit = whisperKit else {
            throw NSError(domain: "Whisperly", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Model not loaded yet"])
        }
        // Whisper needs at least ~0.5 s of audio to behave.
        guard samples.count > 8000 else { return "" }

        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0
        )
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let raw = results.map(\.text).joined(separator: " ")
        return Self.cleanup(raw)
    }

    /// Strips Whisper special tokens and tidies whitespace.
    static func cleanup(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "<\\|[^|]*\\|>",
                                            with: "",
                                            options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper sometimes emits bracketed noise labels on silence.
        let noise = ["[BLANK_AUDIO]", "[NO SPEECH]", "(silence)", "[silence]"]
        if noise.contains(where: { out.caseInsensitiveCompare($0) == .orderedSame }) {
            return ""
        }
        return out
    }
}
