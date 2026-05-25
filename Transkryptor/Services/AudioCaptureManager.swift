import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Lekki opis aplikacji do wyboru w trybie A.
struct CaptureApp: Identifiable, Hashable {
    let processID: pid_t
    let bundleIdentifier: String
    let name: String
    var id: pid_t { processID }
}

/// Okno do graficznego wyboru (z miniaturą podglądu).
struct CaptureWindow: Identifiable {
    let windowID: CGWindowID
    let appName: String
    let title: String
    let thumbnail: NSImage?
    var id: CGWindowID { windowID }
}

/// Przechwytywanie dźwięku przez ScreenCaptureKit.
///
/// KRYTYCZNE: nagrywamy WYŁĄCZNIE dźwięk wychodzący z komputera. Nigdzie w tej klasie
/// nie konfigurujemy wejścia mikrofonowego — bierzemy tylko strumień audio z SCStream.
@MainActor
@Observable
final class AudioCaptureManager {

    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var audioLevel: Float = 0
    private(set) var availableApps: [CaptureApp] = []
    private(set) var availableWindows: [CaptureWindow] = []
    private(set) var isLoadingWindows = false
    /// Poglądowy licznik wykładów w trybie automatycznym (0 = tryb manualny).
    private(set) var currentSegmentIndex = 0
    var errorMessage: String?

    private var stream: SCStream?
    private var output: CaptureOutput?
    private var startDate: Date?
    private var timer: Timer?
    private var recordedURL: URL?
    private var totalPaused: TimeInterval = 0
    private var pauseStarted: Date?
    private var scApplications: [pid_t: SCRunningApplication] = [:]
    private var scWindows: [CGWindowID: SCWindow] = [:]

    private let audioQueue = DispatchQueue(label: "com.franioz.Transkryptor.audio")
    private let videoQueue = DispatchQueue(label: "com.franioz.Transkryptor.video")

    // MARK: - Lista aplikacji (tryb A)

    /// Pobiera aplikacje, które można nagrywać w trybie A.
    /// onScreenWindowsOnly: false → uwzględnia też aplikacje pełnoekranowe (inny Space, np. Safari).
    func refreshAvailableApps() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            let myPID = ProcessInfo.processInfo.processIdentifier
            var apps: [pid_t: SCRunningApplication] = [:]
            for window in content.windows {
                guard let app = window.owningApplication else { continue }
                guard app.processID != myPID else { continue }
                guard !app.applicationName.isEmpty else { continue }
                apps[app.processID] = app
            }
            self.scApplications = apps
            self.availableApps = apps.values
                .map { CaptureApp(processID: $0.processID,
                                  bundleIdentifier: $0.bundleIdentifier,
                                  name: $0.applicationName) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            self.errorMessage = "Nie udało się pobrać listy aplikacji. Sprawdź zgodę na nagrywanie ekranu. (\(error.localizedDescription))"
            self.availableApps = []
        }
    }

    /// Pobiera otwarte okna z miniaturami do graficznego wyboru (tryb A).
    func refreshWindows() async {
        isLoadingWindows = true
        defer { isLoadingWindows = false }
        do {
            // onScreenWindowsOnly: false → uwzględnia okna pełnoekranowe / na innych Spaces
            // (np. Safari na pełnym ekranie), żeby dało się je wybrać.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            let myPID = ProcessInfo.processInfo.processIdentifier
            let windows = content.windows.filter { window in
                guard let app = window.owningApplication, app.processID != myPID else { return false }
                guard window.frame.width > 200, window.frame.height > 120 else { return false }
                // Pomijamy okna bez tytułu (zwykle pomocnicze/niewidoczne).
                guard let title = window.title, !title.isEmpty else { return false }
                return true
            }
            .prefix(30)

            var dict: [CGWindowID: SCWindow] = [:]
            var result: [CaptureWindow] = []
            for window in windows {
                dict[window.windowID] = window
                let thumb = await captureThumbnail(for: window)
                result.append(CaptureWindow(
                    windowID: window.windowID,
                    appName: window.owningApplication?.applicationName ?? "—",
                    title: window.title?.isEmpty == false ? window.title! : (window.owningApplication?.applicationName ?? "Okno"),
                    thumbnail: thumb
                ))
            }
            self.scWindows = dict
            self.availableWindows = result.sorted {
                $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
        } catch {
            self.errorMessage = "Nie udało się pobrać okien. Sprawdź zgodę na nagrywanie ekranu. (\(error.localizedDescription))"
            self.availableWindows = []
        }
    }

    private func captureThumbnail(for window: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = max(window.frame.width / 320, 1)
        config.width = max(Int(window.frame.width / scale), 1)
        config.height = max(Int(window.frame.height / scale), 1)
        config.showsCursor = false
        do {
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: cgImage, size: NSSize(width: config.width, height: config.height))
        } catch {
            return nil
        }
    }

    // MARK: - Start / Stop

    func start(
        mode: CaptureMode,
        applicationPID: pid_t?,
        windowID: CGWindowID? = nil,
        fileURL: URL,
        liveSegmentation: SilenceSegmenter.Params? = nil,
        liveTranscription: Bool = false
    ) async throws {
        guard !isRecording else { return }
        errorMessage = nil

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter: SCContentFilter
        switch mode {
        case .singleApp:
            if let windowID, let window = content.windows.first(where: { $0.windowID == windowID }) {
                // Wybór konkretnego okna (graficzny picker).
                filter = SCContentFilter(desktopIndependentWindow: window)
            } else if let pid = applicationPID,
                      let app = content.applications.first(where: { $0.processID == pid }) ?? scApplications[pid] {
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            } else {
                throw CaptureError.noApplicationSelected
            }
        case .system:
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Minimalne wideo — ScreenCaptureKit wymaga ścieżki obrazu, ale jej nie zapisujemy.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let output = CaptureOutput(
            fileURL: fileURL,
            liveSegmentation: liveSegmentation,
            liveTranscription: liveTranscription,
            onLevel: { [weak self] level in
                Task { @MainActor in self?.audioLevel = level }
            },
            onSegmentBoundary: { [weak self] in
                Task { @MainActor in self?.currentSegmentIndex += 1 }
            },
            onError: { [weak self] message in
                Task { @MainActor in self?.errorMessage = message }
            }
        )
        self.output = output

        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoQueue)
        self.stream = stream

        try await stream.startCapture()

        recordedURL = fileURL
        startDate = Date()
        elapsed = 0
        totalPaused = 0
        pauseStarted = nil
        isPaused = false
        currentSegmentIndex = liveSegmentation == nil ? 0 : 1
        isRecording = true
        startTimer()
    }

    /// Wstrzymuje zapis bez kończenia sesji (czas nie biegnie, audio nie jest zapisywane).
    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pauseStarted = Date()
        audioLevel = 0
        output?.isPaused = true
    }

    func resume() {
        guard isRecording, isPaused else { return }
        if let started = pauseStarted {
            totalPaused += Date().timeIntervalSince(started)
        }
        pauseStarted = nil
        isPaused = false
        output?.isPaused = false
    }

    /// Zatrzymuje nagrywanie i zwraca URL pliku audio (lub nil w razie błędu).
    @discardableResult
    func stop() async -> URL? {
        guard isRecording else { return recordedURL }
        isPaused = false
        pauseStarted = nil
        stopTimer()
        if let stream {
            try? await stream.stopCapture()
        }
        output?.finish()
        stream = nil
        output = nil
        isRecording = false
        audioLevel = 0
        return recordedURL
    }

    /// Pobiera i czyści zebrane próbki 16 kHz mono na potrzeby transkrypcji live.
    func takeLiveSamples() -> [Float] {
        output?.takeLiveSamples() ?? []
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                var t = Date().timeIntervalSince(start) - self.totalPaused
                if let ps = self.pauseStarted { t -= Date().timeIntervalSince(ps) }
                self.elapsed = max(0, t)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        case noApplicationSelected

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "Nie znaleziono ekranu do przechwytywania."
            case .noApplicationSelected: return "Nie wybrano aplikacji do nagrywania."
            }
        }
    }
}

/// Odbiera bufory audio na wątku w tle, zapisuje do pliku i raportuje poziom sygnału.
/// Nonisolated — wywoływany przez ScreenCaptureKit poza głównym aktorem.
private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let fileURL: URL
    private let liveSegmentation: SilenceSegmenter.Params?
    private let liveTranscription: Bool
    private let onLevel: @Sendable (Float) -> Void
    private let onSegmentBoundary: @Sendable () -> Void
    private let onError: @Sendable (String) -> Void
    private var audioFile: AVAudioFile?
    /// Ustawiane z głównego wątku; gdy true, bufory audio są pomijane (pauza).
    var isPaused = false

    // Stan poglądowej detekcji ciszy (tryb automatyczny).
    private var silenceRun = 0.0
    private var sawVoice = false
    private var pendingBoundary = false

    // Downsampling do 16 kHz mono dla transkrypcji live.
    private var liveConverter: AVAudioConverter?
    private var liveFormat: AVAudioFormat?
    private var pendingSamples: [Float] = []
    private let pendingLock = NSLock()

    init(fileURL: URL,
         liveSegmentation: SilenceSegmenter.Params?,
         liveTranscription: Bool,
         onLevel: @escaping @Sendable (Float) -> Void,
         onSegmentBoundary: @escaping @Sendable () -> Void,
         onError: @escaping @Sendable (String) -> Void) {
        self.fileURL = fileURL
        self.liveSegmentation = liveSegmentation
        self.liveTranscription = liveTranscription
        self.onLevel = onLevel
        self.onSegmentBoundary = onSegmentBoundary
        self.onError = onError
    }

    func takeLiveSamples() -> [Float] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        let samples = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        return samples
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }  // obraz świadomie ignorujemy
        guard !isPaused else { return }        // pauza — nie zapisujemy
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        writeAudio(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError("Strumień nagrywania zatrzymany z błędem: \(error.localizedDescription)")
    }

    private func writeAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let format = AVAudioFormat(streamDescription: asbd) else { return }

        if audioFile == nil {
            do {
                audioFile = try AVAudioFile(
                    forWriting: fileURL,
                    settings: format.settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
            } catch {
                onError("Nie udało się utworzyć pliku audio: \(error.localizedDescription)")
                return
            }
        }

        do {
            try sampleBuffer.withAudioBufferList(flags: []) { abl, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl.unsafePointer) else { return }
                try audioFile?.write(from: pcm)
                let rms = Self.rawRMS(pcm)
                onLevel(Self.normalize(rms))
                detectLiveBoundary(rms: rms, frames: Int(pcm.frameLength), sampleRate: format.sampleRate)
                if liveTranscription { appendLiveSamples(from: pcm, sourceFormat: format) }
            }
        } catch {
            onError("Błąd zapisu audio: \(error.localizedDescription)")
        }
    }

    /// Poglądowa detekcja granicy wykładu: po dostatecznie długiej ciszy, gdy dźwięk wraca.
    private func detectLiveBoundary(rms: Float, frames: Int, sampleRate: Double) {
        guard let params = liveSegmentation, sampleRate > 0 else { return }
        let duration = Double(frames) / sampleRate

        if rms < params.threshold {
            if sawVoice {
                silenceRun += duration
                if silenceRun >= params.minSilence { pendingBoundary = true }
            }
        } else {
            if pendingBoundary {
                pendingBoundary = false
                onSegmentBoundary()
            }
            silenceRun = 0
            sawVoice = true
        }
    }

    /// Konwersja bufora do 16 kHz mono Float i dopisanie do bufora live.
    private func appendLiveSamples(from pcm: AVAudioPCMBuffer, sourceFormat: AVAudioFormat) {
        if liveConverter == nil {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false) else { return }
            liveFormat = target
            liveConverter = AVAudioConverter(from: sourceFormat, to: target)
        }
        guard let converter = liveConverter, let target = liveFormat else { return }

        let ratio = target.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 32
        guard outCapacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }

        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true
            status.pointee = .haveData
            return pcm
        }

        var error: NSError?
        converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard error == nil, let channel = outBuffer.floatChannelData else { return }

        let count = Int(outBuffer.frameLength)
        guard count > 0 else { return }
        pendingLock.lock()
        pendingSamples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
        pendingLock.unlock()
    }

    func finish() {
        audioFile = nil
    }

    /// Liniowy RMS pierwszego kanału (0...1) — używany też do detekcji ciszy.
    private static func rawRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sum += s * s
        }
        return sqrt(sum / Float(frames))
    }

    /// Skala logarytmiczna do czytelnego wskaźnika poziomu (0...1).
    private static func normalize(_ rms: Float) -> Float {
        let db = 20 * log10(max(rms, 0.000_000_1))
        let normalized = (db + 60) / 60   // -60 dB -> 0, 0 dB -> 1
        return min(max(normalized, 0), 1)
    }
}
