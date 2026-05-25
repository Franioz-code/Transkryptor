import Foundation
import AVFoundation

/// Segmentacja nagrania sesji po ciszy (heurystyka). Dzieli ciągły plik na wykłady
/// w miejscach dostatecznie długich przerw i przycina ciszę na brzegach segmentów.
struct SilenceSegmenter {

    struct Params: Equatable {
        var minSilence: Double   // s — minimalna cisza uznawana za przerwę
        var threshold: Float     // amplituda RMS (0...1) poniżej której uznajemy ciszę
        var minSegment: Double   // s — krótsze segmenty są odrzucane

        static let `default` = Params(minSilence: 4.0, threshold: 0.02, minSegment: 30.0)

        /// Parametry z ustawień użytkownika (UserDefaults), z sensownymi domyślnymi.
        static func current() -> Params {
            let d = UserDefaults.standard
            return Params(
                minSilence: value(d, SettingsKeys.autoMinSilence, Params.default.minSilence),
                threshold: Float(value(d, SettingsKeys.autoSilenceThreshold, Double(Params.default.threshold))),
                minSegment: value(d, SettingsKeys.autoMinSegment, Params.default.minSegment)
            )
        }

        private static func value(_ d: UserDefaults, _ key: String, _ fallback: Double) -> Double {
            d.object(forKey: key) == nil ? fallback : d.double(forKey: key)
        }
    }

    struct TimeRange: Equatable {
        var start: Double
        var duration: Double
        var end: Double { start + duration }
    }

    // MARK: - Detekcja segmentów

    func detectSegments(in url: URL, params: Params) throws -> [TimeRange] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return [] }

        let windowDuration = 0.1
        let windowFrames = AVAudioFrameCount(sampleRate * windowDuration)
        guard windowFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return []
        }

        var segments: [TimeRange] = []
        var inVoiced = false
        var segmentStart = 0.0
        var lastVoicedEnd = 0.0
        var silenceRun = 0.0
        var elapsed = 0.0
        var anyVoiced = false
        var firstVoiced = 0.0

        // Pętla do framePosition < length — AVAudioFile.read() PO końcu pliku rzuca
        // wyjątek (a nie zwraca 0 ramek), więc nie wolno czytać poza EOF.
        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: windowFrames)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }

            let duration = Double(frames) / sampleRate
            let rms = Self.rms(buffer)
            let isSilent = rms < params.threshold

            if isSilent {
                if inVoiced {
                    silenceRun += duration
                    if silenceRun >= params.minSilence {
                        segments.append(TimeRange(start: segmentStart, duration: lastVoicedEnd - segmentStart))
                        inVoiced = false
                    }
                }
            } else {
                if !anyVoiced { firstVoiced = elapsed; anyVoiced = true }
                if !inVoiced {
                    segmentStart = elapsed
                    inVoiced = true
                }
                silenceRun = 0
                lastVoicedEnd = elapsed + duration
            }
            elapsed += duration
        }

        if inVoiced {
            segments.append(TimeRange(start: segmentStart, duration: lastVoicedEnd - segmentStart))
        }

        let filtered = segments.filter { $0.duration >= params.minSegment }
        if filtered.isEmpty, anyVoiced {
            // Nic nie spełnia minimalnej długości — zwróć całość treści jako jeden segment.
            return [TimeRange(start: firstVoiced, duration: max(lastVoicedEnd - firstVoiced, 0))]
        }
        return filtered
    }

    /// Dzieli długie nagranie na kawałki ~`targetSeconds`, tnąc w ciszy (żeby nie ciąć słów).
    /// Dzięki temu transkrypcja wczytuje do RAM tylko jeden kawałek naraz — zużycie pamięci
    /// jest stałe, niezależnie od długości sesji. Krótkie pliki zwracają jeden zakres.
    func chunkRanges(in url: URL, targetSeconds: Double, maxSeconds: Double, threshold: Float) throws -> [TimeRange] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return [] }
        let total = Double(file.length) / sampleRate
        if total <= maxSeconds { return [TimeRange(start: 0, duration: total)] }

        let windowFrames = AVAudioFrameCount(sampleRate * 0.1)
        guard windowFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return [TimeRange(start: 0, duration: total)]
        }

        var cuts: [Double] = []
        var elapsed = 0.0
        var sinceCut = 0.0
        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: windowFrames)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            let duration = Double(frames) / sampleRate
            let rms = Self.rms(buffer)
            elapsed += duration
            sinceCut += duration
            if sinceCut >= targetSeconds, rms < threshold {
                cuts.append(elapsed); sinceCut = 0          // tnij w ciszy
            } else if sinceCut >= maxSeconds {
                cuts.append(elapsed); sinceCut = 0          // awaryjnie (ciągła mowa) — limit RAM
            }
        }

        var ranges: [TimeRange] = []
        var start = 0.0
        for cut in cuts where cut > start + 1 {
            ranges.append(TimeRange(start: start, duration: cut - start))
            start = cut
        }
        if total - start > 0.05 { ranges.append(TimeRange(start: start, duration: total - start)) }
        return ranges.isEmpty ? [TimeRange(start: 0, duration: total)] : ranges
    }

    // MARK: - Podział pliku (eksport zakresu)

    func export(range: TimeRange, from sourceURL: URL, to destURL: URL) throws {
        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        let sampleRate = format.sampleRate

        let startFrame = AVAudioFramePosition(range.start * sampleRate)
        let totalFrames = AVAudioFramePosition(range.duration * sampleRate)
        guard totalFrames > 0 else { throw SegmentationError.emptyRange }

        try? FileManager.default.removeItem(at: destURL)
        let dest = try AVAudioFile(forWriting: destURL, settings: source.fileFormat.settings)

        source.framePosition = startFrame
        var remaining = totalFrames
        let chunk: AVAudioFrameCount = 32_768

        while remaining > 0 && source.framePosition < source.length {
            let toRead = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else { break }
            try source.read(into: buffer, frameCount: toRead)
            if buffer.frameLength == 0 { break }
            try dest.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
            if buffer.frameLength < toRead { break }
        }
    }

    /// Krótki klip (pierwsze `seconds`) na potrzeby szybkiego podglądu pierwszych słów.
    func previewClip(range: TimeRange, from sourceURL: URL, seconds: Double) throws -> URL {
        let clipped = TimeRange(start: range.start, duration: min(seconds, range.duration))
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        try export(range: clipped, from: sourceURL, to: destURL)
        return destURL
    }

    // MARK: - Pomocnicze

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sum += s * s
        }
        return (sum / Float(frames)).squareRoot()
    }

    enum SegmentationError: LocalizedError {
        case emptyRange
        var errorDescription: String? {
            switch self {
            case .emptyRange: return "Pusty zakres segmentu."
            }
        }
    }
}
