import Foundation
import AVFoundation
import WhisperKit

/// Transkrypcja on-device przez WhisperKit (CoreML, Apple Silicon).
/// Konwersja audio do 16 kHz mono WAV jest po naszej stronie (AVFoundation).
@MainActor
@Observable
final class TranscriptionEngine {

    enum LoadState: Equatable {
        case notLoaded
        case downloading(Double)   // 0...1
        case loading
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    private(set) var state: LoadState = .notLoaded
    private(set) var loadedVariant: String?

    private var whisperKit: WhisperKit?

    /// Czy model jest już gotowy do transkrypcji.
    var isReady: Bool { state == .ready && whisperKit != nil }

    // MARK: - Wybór modelu

    /// Domyślny wariant: turbo large-v3 (~0,6 GB, dobra polszczyzna) — wysoka jakość przy
    /// niskim RAM. Używany wszędzie, gdy użytkownik nie wybrał innego modelu w Ustawieniach.
    static func recommendedDefaultVariant() -> String {
        recommendedHighQualityVariant
    }

    /// Najlżejszy sensowny wariant z dostępnych dla urządzenia (oszczędność RAM):
    /// preferuje kolejno small → base → tiny, inaczej domyślny.
    static func memorySavingVariant() -> String {
        let support = WhisperKit.recommendedModels()
        for key in ["small", "base", "tiny"] {
            if let match = support.supported.first(where: {
                let n = $0.lowercased()
                return n.contains(key) && !n.contains("large") && !n.contains("medium")
            }) {
                return match
            }
        }
        return support.default
    }

    /// Zalecany wariant: wielojęzyczny, skompresowany turbo large-v3 — jakość bliska „large”
    /// przy ~0,6 GB RAM i dobrej polszczyźnie. Stały identyfikator z repo whisperkit-coreml.
    static let recommendedHighQualityVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"

    /// Lista wariantów dostępnych zdalnie (do pickera w ustawieniach). Wymaga sieci.
    static func availableModels() async -> (default: String, supported: [String]) {
        let support = await WhisperKit.recommendedRemoteModels()
        return (support.default, support.supported)
    }

    private func resolvedVariant(_ variant: String?) -> String {
        let trimmed = variant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? Self.recommendedDefaultVariant() : trimmed
    }

    // MARK: - Pobranie + załadowanie modelu

    /// Pobiera pliki modelu do cache, ale NIE ładuje go do pamięci (używane na starcie,
    /// żeby pierwsze nagranie było szybkie, bez trzymania modelu w RAM bezczynnie).
    func ensureDownloaded(variant: String?) async {
        if isReady { return }
        let resolved = resolvedVariant(variant)
        _ = try? await WhisperKit.download(variant: resolved, progressCallback: { _ in })
    }

    /// Zwalnia model z pamięci (ARC oddaje ~kilka GB wag + bufory CoreML).
    func unload() {
        whisperKit = nil
        loadedVariant = nil
        if case .ready = state { state = .notLoaded }
    }

    /// Pobiera (z paskiem postępu) i ładuje model. Idempotentne — jeśli model jest już
    /// pobrany, pobieranie zwróci się szybko z cache. Używane w onboardingu i przy starcie.
    func prepare(variant: String?) async {
        let resolved = resolvedVariant(variant)
        if isReady, loadedVariant == resolved { return }

        state = .downloading(0)
        do {
            // Spróbuj zalecany wariant; jeśli niedostępny, użyj domyślnego dla urządzenia (bezpiecznik).
            var used = resolved
            let folder: URL
            if let f = try? await download(resolved) {
                folder = f
            } else {
                let fallback = WhisperKit.recommendedModels().default
                used = fallback
                folder = try await download(fallback)
            }

            state = .loading
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                verbose: false,
                prewarm: false,   // mniejszy skok pamięci przy ładowaniu (model i tak ładujemy na żądanie)
                load: true,
                download: false
            )
            whisperKit = try await WhisperKit(config)
            loadedVariant = used
            state = .ready
        } catch {
            whisperKit = nil
            state = .failed("Nie udało się przygotować modelu transkrypcji: \(error.localizedDescription)")
        }
    }

    private func download(_ variant: String) async throws -> URL {
        try await WhisperKit.download(variant: variant, progressCallback: { progress in
            Task { @MainActor in
                if case .downloading = self.state {
                    self.state = .downloading(progress.fractionCompleted)
                }
            }
        })
    }

    // MARK: - Transkrypcja

    func transcribe(audioURL: URL) async throws -> String {
        guard let whisperKit, isReady else {
            throw TranscriptionError.notReady
        }
        let wavURL = try convertToWav(source: audioURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "pl",
            usePrefillPrompt: true,
            wordTimestamps: false,
            concurrentWorkerCount: 1,   // 1 = najniższy szczyt RAM (mniej równoległych dekoderów)
            chunkingStrategy: .vad
        )

        let results = try await whisperKit.transcribe(audioPath: wavURL.path, decodeOptions: options)
        return results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transkrypcja surowych próbek 16 kHz mono (do trybu live, fragment po fragmencie).
    func transcribe(samples: [Float]) async throws -> String {
        guard let whisperKit, isReady else { throw TranscriptionError.notReady }
        guard !samples.isEmpty else { return "" }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "pl",
            usePrefillPrompt: true
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Konwersja do 16 kHz mono WAV (AVFoundation)

    private func convertToWav(source: URL) throws -> URL {
        let inputFile = try AVAudioFile(forReading: source)
        let inputFormat = inputFile.processingFormat

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outputFile = try AVAudioFile(forWriting: wavURL, settings: settings)
        let outputFormat = outputFile.processingFormat

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw TranscriptionError.conversionFailed
        }

        let inputBlock: AVAudioConverterInputBlock = { packetCount, outStatus in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: packetCount) else {
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                try inputFile.read(into: buffer)
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
            if buffer.frameLength == 0 {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }

        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_384) else {
                throw TranscriptionError.conversionFailed
            }
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if let error { throw error }
            if outBuffer.frameLength > 0 {
                try outputFile.write(from: outBuffer)
            }
            if status == .endOfStream || status == .error { break }
        }

        return wavURL
    }
}

enum TranscriptionError: LocalizedError {
    case notReady
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .notReady: return "Model transkrypcji nie jest gotowy."
        case .conversionFailed: return "Nie udało się przekonwertować audio do WAV."
        }
    }
}
