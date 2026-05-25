import Foundation
import SwiftData
import CoreGraphics
import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// Spina cały przepływ: nagrywanie -> transkrypcja -> notatki, i trzyma stan dla widoków.
@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case idle
        case recording
        case segmenting
        case transcribing
        case generatingNotes
        case done
        case notesBlocked
        case error(String)

        var label: String {
            switch self {
            case .idle:            return "Gotowe do nagrywania"
            case .recording:       return "Nagrywanie"
            case .segmenting:      return "Dzielę sesję na wykłady"
            case .transcribing:    return "Transkrypcja"
            case .generatingNotes: return "Generuję notatki"
            case .done:            return "Gotowe"
            case .notesBlocked:    return "Transkrypcja gotowa — dodaj klucz API w Ustawieniach, aby wygenerować notatki"
            case let .error(msg):  return "Błąd: \(msg)"
            }
        }

        var isBusy: Bool {
            switch self {
            case .segmenting, .transcribing, .generatingNotes: return true
            default: return false
            }
        }
    }

    let capture = AudioCaptureManager()
    let transcription = TranscriptionEngine()
    let notes = NotesService()
    let storage = StorageService()
    let segmenter = SilenceSegmenter()

    var phase: Phase = .idle {
        didSet {
            if phase.isBusy, !oldValue.isBusy {
                processingStartedAt = Date()
            } else if !phase.isBusy {
                processingStartedAt = nil
            }
        }
    }
    /// Moment startu przetwarzania (do licznika sekund w widoku) — dowód, że nic się nie zacięło.
    var processingStartedAt: Date?
    var statusDetail = ""
    var rawTranscript = ""
    var notesMarkdown = ""
    var selectedLecture: Lecture?
    /// Zwinięcie panelu ustawień nagrywania (żeby notatki miały więcej miejsca).
    var recordPanelCollapsed = false

    // Załączniki (zrzuty ekranu) dołączane do generowania notatek
    var attachedImages: [AttachedImage] = []
    var attachmentContext = ""

    // Współdzielona konfiguracja nagrywania (panel + notch korzystają z tych samych ustawień)
    var recordCourse = ""
    var recordTitle = ""
    var recordMode: CaptureMode = .singleApp
    var recordAppPID: pid_t?
    var recordWindowID: CGWindowID?
    var recordWindowName = ""
    var isAutoMode = false
    var showingWindowPicker = false
    var showingShortcuts = false

    /// Gdy ustawione, najbliższy start dopisze nagranie do tego wykładu (kontynuacja).
    var continuationLecture: Lecture?
    /// Transkrypt sprzed kontynuacji (do doklejenia nowo nagranego fragmentu).
    private var continuationBase: String?

    var canStartRecording: Bool {
        guard !phase.isBusy, !isRecording else { return false }
        guard !recordCourse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if !isAutoMode, recordTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if recordMode == .singleApp { return recordAppPID != nil || recordWindowID != nil }
        return true
    }

    /// Czytelny opis wybranego źródła (do notcha i panelu).
    var recordSourceLabel: String {
        if recordWindowID != nil, !recordWindowName.isEmpty { return recordWindowName }
        if recordMode == .system { return "Cały dźwięk komputera" }
        if let pid = recordAppPID,
           let app = capture.availableApps.first(where: { $0.processID == pid }) { return app.name }
        return "nie wybrano"
    }

    /// Start nagrywania z zapisanej konfiguracji — wołane z panelu i z notcha.
    func startConfiguredRecording() async {
        guard canStartRecording else { return }
        let pid = recordWindowID == nil ? recordAppPID : nil
        if isAutoMode {
            await startAutoSession(course: recordCourse, titlePrefix: recordTitle,
                                   mode: recordMode, appPID: pid, windowID: recordWindowID)
        } else {
            let resume = continuationLecture
            continuationLecture = nil
            await startRecording(course: recordCourse, title: recordTitle,
                                  mode: recordMode, appPID: pid, windowID: recordWindowID,
                                  resume: resume)
        }
    }

    /// Przygotowuje kontynuację wcześniej rozpoczętego wykładu: wczytuje dotychczasowy
    /// transkrypt, wypełnia panel i czeka aż użytkownik wybierze źródło i naciśnie Start.
    /// Nowy fragment zostanie doklejony do istniejącej transkrypcji, a notatki przeliczone.
    func beginContinuation(_ lecture: Lecture) {
        guard !isRecording else { return }
        selectedLecture = lecture
        activeLecture = nil
        continuationLecture = lecture
        isAutoMode = false
        recordCourse = lecture.course
        recordTitle = lecture.title
        recordMode = lecture.mode
        recordAppPID = nil
        recordWindowID = nil
        recordWindowName = ""
        rawTranscript = lecture.transcriptPath.flatMap { storage.readText(at: $0) } ?? ""
        notesMarkdown = lecture.latestNotesPath.flatMap { storage.readText(at: $0) } ?? ""
        clearAttachments()
        recordPanelCollapsed = false   // rozwiń, żeby wybrać źródło i nacisnąć Start
        phase = .idle
    }

    func cancelContinuation() {
        continuationLecture = nil
    }

    /// Otwiera graficzny wybór okna (również z notcha — uaktywnia główne okno).
    func requestWindowPicker() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
        showingWindowPicker = true
    }

    /// Otwiera pełną ściągawkę skrótów (z notcha — uaktywnia główne okno).
    func requestShortcuts() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
        showingShortcuts = true
    }

    /// Pokazuje wskaźnik w notchu i rejestruje globalne skróty (start aplikacji).
    func showIndicator() {
        notch.start()
        registerHotkeys()
    }

    // MARK: - Globalne skróty + zrzuty

    private func registerHotkeys() {
        guard hotkeys.isEmpty else { return }
        let mods = UInt32(cmdKey | optionKey)
        if let h = GlobalHotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: mods,
                                handler: { [weak self] in self?.captureRegionScreenshot() }) {
            hotkeys.append(h)
        }
        if let h = GlobalHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: mods,
                                handler: { [weak self] in self?.setScreenshotRegion() }) {
            hotkeys.append(h)
        }
    }

    /// Zrzut zapamiętanego obszaru (⌥⌘S). Jeśli obszaru jeszcze nie ma — pyta o zaznaczenie.
    func captureRegionScreenshot() {
        let time = capture.elapsed
        guard let region = screenshotService.savedRegion else { setScreenshotRegion(); return }
        if let image = screenshotService.capture(region: region) {
            addImage(image, at: time)
            flashScreenshot()
        }
    }

    /// Zaznaczenie/zmiana obszaru zrzutu (⌥⌘R lub z ustawień).
    func setScreenshotRegion() {
        let time = capture.elapsed
        notch.hideForOverlay()   // schowaj wskaźnik, żeby nie zasłaniał ekranu
        screenshotService.selectRegion { [weak self] rect in
            guard let self else { return }
            guard let rect else { self.notch.restoreAfterOverlay(); return }
            self.screenshotService.saveRegion(rect)
            // Łap zrzut, gdy notch jest jeszcze schowany (żeby nie trafił w kadr).
            let image = self.screenshotService.capture(region: rect)
            self.notch.restoreAfterOverlay()
            if let image {
                self.addImage(image, at: time)
                self.flashScreenshot()
            }
        }
    }

    var hasScreenshotRegion: Bool { screenshotService.savedRegion != nil }

    /// Wywołanie z przycisku w notchu: panel ustawień aktywował apkę (do pisania),
    /// więc najpierw oddajemy aktywność (wraca poprzednia apka / pełny ekran Safari),
    /// a dopiero potem pokazujemy nakładkę zaznaczania — żeby była nad właściwym widokiem.
    func setScreenshotRegionFromButton() {
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.setScreenshotRegion()
        }
    }

    private func flashScreenshot() {
        screenshotFlash = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.screenshotFlash = false
        }
    }

    static func timeLabel(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // Tryb automatyczny
    var pendingSegments: [ReviewSegment] = []
    var showingSegmentReview = false
    private var sessionURL: URL?
    private var sessionCourse = ""
    private var sessionTitlePrefix = ""
    private var sessionMode: CaptureMode = .singleApp

    private var activeLecture: Lecture?
    /// Lektura, do której na bieżąco zapisujemy transkrypt live (siatka bezpieczeństwa).
    private var liveLecture: Lecture?
    /// Lektura-odzysk dla sesji auto (pełna transkrypcja sesji, gdyby podział zawiódł/crash).
    private var recoveryLecture: Lecture?
    private(set) var isAutoActive = false
    var modelContext: ModelContext?

    // Transkrypcja live
    private var liveTask: Task<Void, Never>?
    private var liveAccumulator: [Float] = []
    private var usedLive = false

    var liveTranscriptionEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.liveTranscription) == nil
            ? true
            : UserDefaults.standard.bool(forKey: SettingsKeys.liveTranscription)
    }

    @ObservationIgnored private var _notch: NotchStatusController?
    private var notch: NotchStatusController {
        if let _notch { return _notch }
        let controller = NotchStatusController(appModel: self)
        _notch = controller
        return controller
    }

    @ObservationIgnored private let screenshotService = ScreenshotService()
    @ObservationIgnored private var hotkeys: [GlobalHotKey] = []
    /// Krótkie mrugnięcie w notchu po zrobieniu zrzutu.
    var screenshotFlash = false
    /// Zwiększane po przycięciu zrzutu — wymusza odświeżenie galerii i podglądu notatek.
    var galleryRefresh = 0

    var isRecording: Bool { capture.isRecording }
    var isPaused: Bool { capture.isPaused }
    var hasAPIKey: Bool { KeychainService.hasAPIKey }

    /// Katalog bazowy do rozwiązywania ścieżek obrazów w podglądzie notatek.
    var notesBaseURL: URL? {
        guard let lec = selectedLecture else { return nil }
        return storage.notesDirectory(course: lec.course)
    }

    /// Zapisane na dysku zrzuty wybranego wykładu (do galerii). Posortowane wg czasu.
    var lectureScreenshots: [SavedScreenshot] {
        guard let lec = selectedLecture else { return [] }
        return storage.loadScreenshots(course: lec.course, title: lec.title, date: lec.date)
    }

    func togglePause() {
        if capture.isPaused { capture.resume() } else { capture.pause() }
    }

    // MARK: - Załączniki

    /// Wykład, do którego trafiają nowe zrzuty (nagrywany albo otwarty).
    private var currentScreenshotLecture: Lecture? { liveLecture ?? selectedLecture }

    func addImage(_ image: NSImage, at time: TimeInterval = 0) {
        let (data, ext) = Self.screenshotForDisk(image)   // skompresowany (mniejszy plik na dysku)
        guard !data.isEmpty else { return }
        var item = AttachedImage(image: image, data: data, timestamp: time)
        // Zapis OD RAZU na dysk — nawet crash w środku sesji nie zgubi zrzutu.
        if let lec = currentScreenshotLecture {
            let filename = "zrzut-\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
            if (try? storage.saveAssetImage(data, name: filename, course: lec.course,
                                            title: lec.title, date: lec.date)) != nil {
                item.savedURL = storage.assetsDirectory(course: lec.course, title: lec.title, date: lec.date)
                    .appendingPathComponent(filename)
                item.assetFilename = filename
            }
        }
        attachedImages.append(item)
        persistScreenshotMeta()
    }

    /// Kompresuje zrzut do zapisu na dysku: zmniejsza bardzo duże (Retina) i koduje JPEG ~0.85.
    /// Mocno ogranicza rozmiar plików, zachowując czytelność. Przezroczystość zastępuje białym tłem.
    static func screenshotForDisk(_ image: NSImage) -> (data: Data, ext: String) {
        let maxEdge: CGFloat = 2400
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return (image.pngDataRepresentation() ?? Data(), "png")
        }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxEdge / max(w, h, 1))
        let targetW = max(1, Int((w * scale).rounded()))
        let targetH = max(1, Int((h * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: targetW, pixelsHigh: targetH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            return (image.pngDataRepresentation() ?? Data(), "png")
        }
        rep.size = NSSize(width: targetW, height: targetH)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.set()
        NSRect(x: 0, y: 0, width: targetW, height: targetH).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            return (jpeg, "jpg")
        }
        return (image.pngDataRepresentation() ?? Data(), "png")
    }

    func removeAttachment(_ id: UUID) {
        if let item = attachedImages.first(where: { $0.id == id }), let url = item.savedURL {
            try? FileManager.default.removeItem(at: url)   // trwałe usunięcie z dysku
        }
        attachedImages.removeAll { $0.id == id }
        persistScreenshotMeta()
        galleryRefresh += 1
    }

    func clearAttachments() {
        attachedImages = []
        attachmentContext = ""
    }

    /// Zapisuje `_meta.json` (nazwa pliku → czas) dla bieżącego wykładu na podstawie zrzutów w pamięci.
    private func persistScreenshotMeta() {
        guard let lec = currentScreenshotLecture else { return }
        let entries = attachedImages.compactMap { shot -> (file: String, time: TimeInterval)? in
            guard let f = shot.assetFilename else { return nil }
            return (file: f, time: shot.timestamp)
        }
        guard !entries.isEmpty else { return }
        storage.saveScreenshotMetaEntries(entries, course: lec.course, title: lec.title, date: lec.date)
    }

    // MARK: - Przycinanie zrzutów

    /// Przycina zapisany na dysku zrzut do zaznaczonego obszaru (`normalized` w zakresie 0…1,
    /// układ od lewego-górnego rogu). Nadpisuje plik, więc zmiana widać też w notatkach.
    func cropSavedScreenshot(at url: URL, normalized: CGRect) {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data),
              let croppedPng = croppedPNG(of: image, normalized: normalized),
              let croppedImage = NSImage(data: croppedPng) else { return }
        let (compressed, _) = Self.screenshotForDisk(croppedImage)
        try? (compressed.isEmpty ? croppedPng : compressed).write(to: url)
        galleryRefresh += 1
    }

    /// Przycina zrzut roboczy (z pamięci sesji) do zaznaczonego obszaru.
    func cropAttachment(_ id: UUID, normalized: CGRect) {
        guard let idx = attachedImages.firstIndex(where: { $0.id == id }) else { return }
        let item = attachedImages[idx]
        guard let png = croppedPNG(of: item.image, normalized: normalized),
              let image = NSImage(data: png) else { return }
        let (compressed, _) = Self.screenshotForDisk(image)
        let diskData = compressed.isEmpty ? png : compressed
        var newItem = AttachedImage(image: image, data: diskData, timestamp: item.timestamp)
        newItem.savedURL = item.savedURL
        newItem.assetFilename = item.assetFilename
        if let url = item.savedURL { try? diskData.write(to: url) }   // nadpisz zapisany plik (skompresowany)
        attachedImages[idx] = newItem
        galleryRefresh += 1
    }

    /// Wycina prostokąt (znormalizowany 0…1, lewy-górny róg) z obrazu i zwraca PNG.
    private func croppedPNG(of image: NSImage, normalized: CGRect) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(x: normalized.minX * w, y: normalized.minY * h,
                          width: normalized.width * w, height: normalized.height * h)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            .integral
        guard rect.width >= 1, rect.height >= 1, let cropped = cg.cropping(to: rect) else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
    }

    // MARK: - Model transkrypcji

    private var storedTranscriptionVariant: String? {
        UserDefaults.standard.string(forKey: SettingsKeys.transcriptionModelVariant)
    }

    /// Na starcie tylko POBIERAMY model (do cache), bez ładowania do RAM. Model trafia do
    /// pamięci dopiero przy nagrywaniu/transkrypcji i jest zwalniany po przetworzeniu.
    /// `unload()` zwalnia też model ewentualnie wczytany w onboardingu.
    func prepareModelOnLaunch() async {
        transcription.unload()
        await transcription.ensureDownloaded(variant: storedTranscriptionVariant)
    }

    /// Ładuje model do pamięci tuż przed użyciem (idempotentne — szybkie, gdy już gotowy).
    private func ensureModelReady() async {
        if transcription.isReady { return }
        statusDetail = "Ładuję model transkrypcji…"
        await transcription.prepare(variant: storedTranscriptionVariant)
        statusDetail = ""
    }

    /// Transkrybuje plik kawałkami (cięcie w ciszy) — RAM pozostaje stały niezależnie od długości
    /// sesji, bo do pamięci trafia tylko jeden ~8-min fragment naraz. Krótkie pliki idą w całości.
    private func transcribeLong(_ audioURL: URL) async throws -> String {
        let ranges = (try? segmenter.chunkRanges(
            in: audioURL, targetSeconds: 8 * 60, maxSeconds: 12 * 60,
            threshold: SilenceSegmenter.Params.current().threshold
        )) ?? []
        guard ranges.count > 1 else {
            return try await transcription.transcribe(audioURL: audioURL)
        }

        let fm = FileManager.default
        var parts: [String] = []
        for (index, range) in ranges.enumerated() {
            statusDetail = "Transkrypcja: część \(index + 1)/\(ranges.count)"
            let chunkURL = fm.temporaryDirectory
                .appendingPathComponent("chunk-\(UUID().uuidString).caf")
            do {
                try segmenter.export(range: range, from: audioURL, to: chunkURL)
                let text = try await transcription.transcribe(audioURL: chunkURL)
                if !text.isEmpty { parts.append(text) }
            } catch {
                // Pojedynczy fragment zawiódł — nie tracimy całości reszty.
            }
            try? fm.removeItem(at: chunkURL)
        }
        statusDetail = ""
        return parts.joined(separator: " ")
    }

    /// Po crashu: lektury oznaczone „(w toku)" mają już na dysku transkrypt do momentu awarii.
    /// Oznaczamy je jako odzyskane, żeby były czytelne w historii (nic nie przepada).
    func recoverInterruptedSessions() {
        guard let ctx = modelContext else { return }
        guard let all = try? ctx.fetch(FetchDescriptor<Lecture>()) else { return }
        var changed = false
        for lecture in all where lecture.title.contains("(w toku)") {
            lecture.title = lecture.title.replacingOccurrences(of: "(w toku)", with: "(odzyskane)")
            changed = true
        }
        if changed { try? ctx.save() }
    }

    // MARK: - Nagrywanie

    func startRecording(course: String, title: String, mode: CaptureMode, appPID: pid_t?,
                        windowID: CGWindowID? = nil, resume: Lecture? = nil) async {
        let trimmedCourse = course.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCourse.isEmpty, !trimmedTitle.isEmpty else {
            phase = .error("Podaj nazwę kursu i tytuł wykładu.")
            return
        }

        do {
            let audioURL = try storage.newAudioFileURL(course: trimmedCourse, title: trimmedTitle)
            // Model ładujemy do RAM tylko, gdy potrzebny (transkrypcja live); inaczej dopiero przy stopie.
            if liveTranscriptionEnabled { await ensureModelReady() }
            let live = liveTranscriptionEnabled && transcription.isReady
            try await capture.start(
                mode: mode, applicationPID: appPID, windowID: windowID,
                fileURL: audioURL, liveTranscription: live
            )

            let lecture: Lecture
            if let resume {
                lecture = resume
                continuationBase = resume.transcriptPath.flatMap { storage.readText(at: $0) } ?? ""
                rawTranscript = continuationBase ?? ""
            } else {
                lecture = Lecture(course: trimmedCourse, title: trimmedTitle, mode: mode)
                lecture.audioPath = audioURL.path
                modelContext?.insert(lecture)
                continuationBase = nil
                rawTranscript = ""
            }
            try? modelContext?.save()

            activeLecture = lecture
            liveLecture = lecture
            recoveryLecture = nil
            selectedLecture = lecture
            notesMarkdown = ""
            isAutoActive = false
            phase = .recording
            notch.start()
            if live { startLiveLoop(preserveTranscript: resume != nil) }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Pętla transkrypcji live

    private func startLiveLoop(preserveTranscript: Bool = false) {
        usedLive = true
        liveAccumulator = []
        if !preserveTranscript { rawTranscript = "" }
        liveTask = Task { [weak self] in
            guard let self else { return }
            while self.capture.isRecording {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await self.pumpLive(minSeconds: 6)
            }
        }
    }

    private func pumpLive(minSeconds: Double) async {
        let newSamples = capture.takeLiveSamples()
        if !newSamples.isEmpty { liveAccumulator.append(contentsOf: newSamples) }
        let needed = Int(16_000 * minSeconds)
        guard liveAccumulator.count >= needed else { return }
        let chunk = liveAccumulator
        liveAccumulator.removeAll(keepingCapacity: true)
        if let text = try? await transcription.transcribe(samples: chunk) {
            if !text.isEmpty { appendLive(text) }   // pusty = cisza, fragment skonsumowany
        } else {
            // Transkrypcja fragmentu zawiodła — nie gub próbek; spróbuj z kolejnymi.
            liveAccumulator.insert(contentsOf: chunk, at: 0)
            let cap = Int(16_000 * 90)   // ogranicz do ~90 s, gdyby model padał w kółko
            if liveAccumulator.count > cap {
                liveAccumulator.removeFirst(liveAccumulator.count - cap)
            }
        }
    }

    private func finalizeLive() async {
        liveTask?.cancel()
        _ = await liveTask?.value
        liveTask = nil
        let remaining = capture.takeLiveSamples()
        if !remaining.isEmpty { liveAccumulator.append(contentsOf: remaining) }
        if !liveAccumulator.isEmpty {
            if let text = try? await transcription.transcribe(samples: liveAccumulator), !text.isEmpty {
                appendLive(text)
            }
            liveAccumulator.removeAll()
        }
        usedLive = false
    }

    private func appendLive(_ text: String) {
        rawTranscript += (rawTranscript.isEmpty ? "" : " ") + text
        persistLiveTranscript()
    }

    /// Generuje notatki, zapisując najpierw zrzuty na dysk (obok .md) i każąc AI wstawić je
    /// jako obrazy `![…](plik)` we właściwych miejscach. `timeOffset` przelicza czas dla segmentu.
    private func makeNotes(transcript: String, course: String, title: String, date: Date,
                           shots: [AttachedImage], timeOffset: TimeInterval = 0, style: String,
                           imageContext: String) async throws -> String {
        let targetBase = storage.fileBase(title: title, date: date)
        let targetAssetsName = "\(targetBase).assets"
        var datas: [Data] = []
        var times: [String] = []
        var relPaths: [String] = []
        var metaEntries: [(file: String, time: TimeInterval)] = []
        var freshIndex = 0
        for shot in shots {
            let t = max(0, shot.timestamp - timeOffset)
            datas.append(shot.data)
            times.append(Self.timeLabel(t))

            // Jeśli zrzut jest już zapisany w docelowym folderze (zapis przy zrobieniu),
            // używamy istniejącego pliku — bez duplikatów i przenumerowywania.
            var filename: String?
            if let saved = shot.assetFilename, let url = shot.savedURL,
               url.deletingLastPathComponent().lastPathComponent == targetAssetsName,
               FileManager.default.fileExists(atPath: url.path) {
                filename = saved
            } else {
                freshIndex += 1
                // Unikalna nazwa (czas + indeks) — nigdy nie nadpisze istniejącego pliku.
                let name = "zrzut-\(Int(Date().timeIntervalSince1970 * 1000))-\(freshIndex).png"
                if (try? storage.saveAssetImage(shot.data, name: name, course: course, title: title, date: date)) != nil {
                    filename = name
                }
            }
            if let filename {
                relPaths.append("\(targetAssetsName)/\(filename)")
                metaEntries.append((file: filename, time: t))
            }
        }
        storage.saveScreenshotMetaEntries(metaEntries, course: course, title: title, date: date)
        let names = (relPaths.count == datas.count) ? relPaths : []   // spójność: wszystkie albo żadne
        let raw = try await notes.generate(
            transcript: transcript, style: style, model: notesModel,
            images: datas, imageTimes: times, imageFilenames: names, imageContext: imageContext
        )
        // Diagramy mermaid i wzory ($$…$$ / \ce{}) → obrazy, żeby wyglądały dobrze
        // i przechodziły do Apple Notes / PDF tak jak zrzuty.
        return await DiagramRasterizer.shared.process(
            markdown: raw, course: course, title: title, date: date, storage: storage
        )
    }

    /// Zapisuje bieżący transkrypt na DYSK po każdym fragmencie — gwarancja, że nawet
    /// przy crashu po 2h zostaje pełna transkrypcja słowo w słowo (i wpis w historii).
    private func persistLiveTranscript() {
        guard let lec = liveLecture, !rawTranscript.isEmpty else { return }
        if let url = try? storage.saveTranscript(rawTranscript, course: lec.course, title: lec.title, date: lec.date) {
            lec.transcriptPath = url.path
        }
        try? modelContext?.save()
    }

    func stopAndProcess() async {
        guard let lecture = activeLecture else { return }
        defer { transcription.unload() }   // zwolnij model z RAM po zakończeniu przetwarzania
        // Snapshot zrzutów PRZED jakimkolwiek await — przełączenie wykładu w trakcie
        // przetwarzania (które czyści attachedImages) nie może już wymazać tych zrzutów.
        let shots = attachedImages
        let context = attachmentContext
        let duration = capture.elapsed
        let audioURL = await capture.stop()
        lecture.durationSeconds = duration

        guard let audioURL else {
            phase = .error("Brak nagrania audio.")
            return
        }

        do {
            phase = .transcribing
            let transcript: String
            if usedLive {
                await finalizeLive()
                transcript = rawTranscript   // przy kontynuacji rawTranscript zawiera już bazę
            } else {
                await ensureModelReady()   // nagranie nie-live: ładujemy model dopiero teraz
                let newText = try await transcribeLong(audioURL)
                if let base = continuationBase, !base.isEmpty {
                    transcript = base + "\n\n" + newText   // doklej do wcześniejszej transkrypcji
                } else {
                    transcript = newText
                }
                if selectedLecture === lecture { rawTranscript = transcript }
            }
            continuationBase = nil
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                phase = .error("Pusta transkrypcja — brak rozpoznanej mowy.")
                return
            }
            let txtURL = try storage.saveTranscript(transcript, course: lecture.course, title: lecture.title, date: lecture.date)
            lecture.transcriptPath = txtURL.path
            try? modelContext?.save()

            // Bez klucza API transkrypcja (lokalna) jest gotowa, ale notatek nie generujemy.
            guard hasAPIKey else {
                // Transkrypt zapisany — audio jest już zbędne (chyba że użytkownik chce je zachować).
                cleanupAudio([audioURL.path, lecture.audioPath], clearOn: lecture)
                try? modelContext?.save()
                phase = .notesBlocked
                return
            }

            phase = .generatingNotes
            let style = UserDefaults.standard.string(forKey: SettingsKeys.defaultNotesStyle) ?? ""
            let md = try await makeNotes(
                transcript: transcript, course: lecture.course, title: lecture.title,
                date: lecture.date, shots: shots, style: style, imageContext: context
            )
            let mdURL = try storage.saveNotes(md, course: lecture.course, title: lecture.title, date: lecture.date, version: 1)
            lecture.notesPaths = [mdURL.path]
            lecture.usedStyle = style
            // Notatki gotowe — audio jest zbędne (notatki/transkrypt powstają z tekstu).
            cleanupAudio([audioURL.path, lecture.audioPath], clearOn: lecture)
            try? modelContext?.save()
            if selectedLecture === lecture { notesMarkdown = md }   // nie nadpisuj innego, otwartego wykładu
            clearAttachments()   // zwolnij obrazy z pamięci (są już na dysku)

            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Tryb automatyczny: sesja

    func startAutoSession(course: String, titlePrefix: String, mode: CaptureMode, appPID: pid_t?, windowID: CGWindowID? = nil) async {
        let trimmedCourse = course.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCourse.isEmpty else {
            phase = .error("Podaj nazwę kursu.")
            return
        }
        do {
            let audioURL = try storage.newSessionFileURL(course: trimmedCourse)
            if liveTranscriptionEnabled { await ensureModelReady() }
            let live = liveTranscriptionEnabled && transcription.isReady
            try await capture.start(
                mode: mode, applicationPID: appPID, windowID: windowID, fileURL: audioURL,
                liveSegmentation: SilenceSegmenter.Params.current(),
                liveTranscription: live
            )
            sessionURL = audioURL
            sessionCourse = trimmedCourse
            sessionTitlePrefix = titlePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            sessionMode = mode
            activeLecture = nil
            rawTranscript = ""
            notesMarkdown = ""
            pendingSegments = []
            isAutoActive = true

            // Siatka bezpieczeństwa: lektura-odzysk z pełną transkrypcją całej sesji.
            let prefix = sessionTitlePrefix.isEmpty ? "Wykład" : sessionTitlePrefix
            let recovery = Lecture(course: trimmedCourse, title: "\(prefix) — sesja (w toku)", mode: mode)
            recovery.audioPath = audioURL.path
            modelContext?.insert(recovery)
            recoveryLecture = recovery
            liveLecture = recovery
            selectedLecture = recovery
            try? modelContext?.save()

            phase = .recording
            notch.start()
            if live { startLiveLoop() }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func endAutoSession() async {
        let url = await capture.stop()
        // Domknij transkrypt live (siatka bezpieczeństwa już jest na dysku).
        if usedLive { await finalizeLive() }

        guard let url else {
            // Nawet bez audio — jeśli mamy transkrypt live, zachowujemy go jako wpis.
            await finalizeRecoveryAsWhole(reason: "Brak pliku nagrania sesji.")
            return
        }
        phase = .segmenting
        let params = SilenceSegmenter.Params.current()
        do {
            let ranges = try await Task.detached(priority: .userInitiated) {
                try SilenceSegmenter().detectSegments(in: url, params: params)
            }.value

            let prefix = sessionTitlePrefix.isEmpty ? "Wykład" : sessionTitlePrefix
            pendingSegments = ranges.enumerated().map { index, range in
                ReviewSegment(start: range.start, duration: range.duration, title: "\(prefix) \(index + 1)")
            }

            if pendingSegments.isEmpty {
                // Brak segmentów → zachowaj całą sesję jako jeden wpis (z pełną transkrypcją).
                await finalizeRecoveryAsWhole(reason: nil)
                return
            }

            showingSegmentReview = true
            phase = .idle
            await generatePreviews()
        } catch {
            // Podział zawiódł → NIE tracimy nic: cała sesja zostaje jako jeden wpis z transkrypcją.
            await finalizeRecoveryAsWhole(reason: "Podział na wykłady się nie udał: \(error.localizedDescription)")
        }
    }

    /// Fallback: zachowuje całą sesję jako jeden wpis z pełną transkrypcją (i notatkami, jeśli jest klucz).
    /// Wołane, gdy podział zawiedzie lub użytkownik anuluje korektę — żeby NIGDY nie stracić materiału.
    private func finalizeRecoveryAsWhole(reason: String?) async {
        guard let rec = recoveryLecture else {
            phase = reason.map { .error($0) } ?? .error("Brak nagrania sesji.")
            return
        }
        defer { transcription.unload() }   // zwolnij model z RAM po zakończeniu
        let prefix = sessionTitlePrefix.isEmpty ? "Wykład" : sessionTitlePrefix
        rec.title = "\(prefix) — cała sesja"
        rec.durationSeconds = capture.elapsed

        // Jeśli z jakiegoś powodu nie ma transkryptu live — dotranskrybuj cały plik.
        if rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let url = sessionURL {
            phase = .transcribing
            await ensureModelReady()
            if let t = try? await transcribeLong(url) { rawTranscript = t }
        }
        if let url = try? storage.saveTranscript(rawTranscript, course: rec.course, title: rec.title, date: rec.date) {
            rec.transcriptPath = url.path
        }
        selectedLecture = rec
        liveLecture = nil

        if hasAPIKey, !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phase = .generatingNotes
            let style = UserDefaults.standard.string(forKey: SettingsKeys.defaultNotesStyle) ?? ""
            if let md = try? await makeNotes(transcript: rawTranscript, course: rec.course, title: rec.title,
                                             date: rec.date, shots: attachedImages, style: style,
                                             imageContext: attachmentContext) {
                notesMarkdown = md
                if let mdURL = try? storage.saveNotes(md, course: rec.course, title: rec.title, date: rec.date, version: 1) {
                    rec.notesPaths = [mdURL.path]
                    rec.usedStyle = style
                }
            }
        }
        // Transkrypt zapisany — duży plik sesji audio nie jest już potrzebny.
        cleanupAudio([rec.audioPath, sessionURL?.path], clearOn: rec)
        clearAttachments()
        try? modelContext?.save()
        recoveryLecture = nil

        if let reason {
            phase = .error("\(reason) Zapisano całą sesję jako jeden wpis z pełną transkrypcją.")
        } else {
            phase = hasAPIKey ? .done : .notesBlocked
        }
    }

    /// Szybki podgląd pierwszych słów każdego segmentu (krótki klip + model lokalny).
    private func generatePreviews() async {
        guard let url = sessionURL else { return }
        await ensureModelReady()
        guard transcription.isReady else { return }
        for index in pendingSegments.indices {
            guard showingSegmentReview else { return }
            pendingSegments[index].previewLoading = true
            do {
                let clip = try segmenter.previewClip(range: pendingSegments[index].range, from: url, seconds: 18)
                defer { try? FileManager.default.removeItem(at: clip) }
                let text = try await transcription.transcribe(audioURL: clip)
                guard index < pendingSegments.count else { return }
                let words = text.split(separator: " ").prefix(14).joined(separator: " ")
                pendingSegments[index].preview = words.isEmpty ? "(brak rozpoznanej mowy)" : words + "…"
            } catch {
                if index < pendingSegments.count { pendingSegments[index].preview = "(podgląd niedostępny)" }
            }
            if index < pendingSegments.count { pendingSegments[index].previewLoading = false }
        }
    }

    // MARK: - Korekta segmentów

    func mergeSegmentForward(_ id: UUID) {
        guard let idx = pendingSegments.firstIndex(where: { $0.id == id }), idx + 1 < pendingSegments.count else { return }
        let next = pendingSegments[idx + 1]
        pendingSegments[idx].duration = next.end - pendingSegments[idx].start
        pendingSegments.remove(at: idx + 1)
    }

    func splitSegment(_ id: UUID, atAbsoluteTime time: Double) {
        guard let idx = pendingSegments.firstIndex(where: { $0.id == id }) else { return }
        let seg = pendingSegments[idx]
        guard time > seg.start, time < seg.end else { return }
        let first = ReviewSegment(start: seg.start, duration: time - seg.start, title: seg.title)
        let second = ReviewSegment(start: time, duration: seg.end - time, title: seg.title + " (2)")
        pendingSegments.replaceSubrange(idx...idx, with: [first, second])
    }

    func deleteSegment(_ id: UUID) {
        pendingSegments.removeAll { $0.id == id }
    }

    func renameSegment(_ id: UUID, title: String) {
        guard let idx = pendingSegments.firstIndex(where: { $0.id == id }) else { return }
        pendingSegments[idx].title = title
    }

    func cancelSegmentReview() {
        showingSegmentReview = false
        pendingSegments = []
        // Anulowanie podziału NIE kasuje materiału — zostaje cała sesja jako jeden wpis z transkrypcją.
        if let rec = recoveryLecture {
            let prefix = sessionTitlePrefix.isEmpty ? "Wykład" : sessionTitlePrefix
            rec.title = "\(prefix) — cała sesja"
            rec.durationSeconds = capture.elapsed
            selectedLecture = rec
            if let path = rec.transcriptPath, let t = storage.readText(at: path) { rawTranscript = t }
            try? modelContext?.save()
            recoveryLecture = nil
            liveLecture = nil
            phase = .done
        } else {
            phase = .idle
        }
    }

    /// Zadanie przetwarzania (transkrypcja + notatki). Trzymane przez model — działa w tle,
    /// niezależnie od tego, który wykład oglądasz i co robisz dalej na komputerze.
    private var processingTask: Task<Void, Never>?

    /// Wywoływane z panelu w notchu / paska menu — kończy bieżącą sesję właściwą metodą.
    func stopFromIndicator() {
        guard isRecording else { return }
        processingTask = Task { [self] in
            if isAutoActive { await endAutoSession() }
            else { await stopAndProcess() }
        }
    }

    /// Ponowne wygenerowanie notatek w tle (z nowym stylem).
    func regenerateInBackground(style: String, rememberAsDefault: Bool) {
        processingTask = Task { [self] in
            await regenerate(style: style, rememberAsDefault: rememberAsDefault)
        }
    }

    /// Przetwarzanie zaakceptowanych segmentów w tle.
    func processSegmentsInBackground() {
        processingTask = Task { [self] in await processSegments() }
    }

    // MARK: - Przetwarzanie zaakceptowanych segmentów

    func processSegments() async {
        guard let url = sessionURL, !pendingSegments.isEmpty else { return }
        defer { transcription.unload() }   // zwolnij model z RAM po przetworzeniu segmentów
        await ensureModelReady()
        // Segmenty zastępują lekturę-odzysk — usuwamy ją (każdy wykład będzie osobnym wpisem).
        if let rec = recoveryLecture {
            modelContext?.delete(rec)
            recoveryLecture = nil
            liveLecture = nil
            try? modelContext?.save()
        }
        let segments = pendingSegments
        let allShots = attachedImages        // snapshot przed przetwarzaniem (navigacja nie wymaże)
        let context = attachmentContext
        showingSegmentReview = false
        let total = segments.count

        for (i, seg) in segments.enumerated() {
            let title = seg.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Wykład \(i + 1)" : seg.title
            statusDetail = "Wykład \(i + 1) z \(total)"
            do {
                phase = .transcribing
                let segURL = try storage.newAudioFileURL(course: sessionCourse, title: title)
                try segmenter.export(range: seg.range, from: url, to: segURL)
                let transcript = try await transcribeLong(segURL)

                let lecture = Lecture(course: sessionCourse, title: title, mode: sessionMode)
                let txtURL = try storage.saveTranscript(transcript, course: sessionCourse, title: title, date: lecture.date)
                lecture.audioPath = segURL.path
                lecture.transcriptPath = txtURL.path
                lecture.durationSeconds = seg.duration
                modelContext?.insert(lecture)

                rawTranscript = transcript
                notesMarkdown = ""
                selectedLecture = lecture

                if hasAPIKey {
                    phase = .generatingNotes
                    let style = UserDefaults.standard.string(forKey: SettingsKeys.defaultNotesStyle) ?? ""
                    // Zrzuty z czasem w zakresie tego segmentu (czas liczony od początku wykładu).
                    let segShots = allShots.filter { $0.timestamp >= seg.start && $0.timestamp <= seg.end }
                    let md = try await makeNotes(
                        transcript: transcript, course: sessionCourse, title: title,
                        date: lecture.date, shots: segShots, timeOffset: seg.start, style: style,
                        imageContext: context
                    )
                    let mdURL = try storage.saveNotes(md, course: sessionCourse, title: title, date: lecture.date, version: 1)
                    lecture.notesPaths = [mdURL.path]
                    lecture.usedStyle = style
                    if selectedLecture === lecture { notesMarkdown = md }
                }
                // Audio segmentu jest zbędne po zapisaniu transkryptu/notatek.
                cleanupAudio([segURL.path], clearOn: lecture)
                try? modelContext?.save()
            } catch {
                phase = .error("Wykład \(i + 1): \(error.localizedDescription)")
                statusDetail = ""
                return
            }
        }

        // Wielki plik całej sesji nie jest już potrzebny — segmenty mają własny materiał.
        try? FileManager.default.removeItem(at: url)
        clearAttachments()
        statusDetail = ""
        pendingSegments = []
        phase = hasAPIKey ? .done : .notesBlocked
    }

    // MARK: - Regeneracja notatek (zmieniony styl)

    func regenerate(style: String, rememberAsDefault: Bool) async {
        guard let lecture = selectedLecture ?? activeLecture else { return }
        guard !rawTranscript.isEmpty else {
            phase = .error("Brak transkrypcji do ponownego wygenerowania.")
            return
        }
        guard hasAPIKey else {
            phase = .notesBlocked
            return
        }
        if rememberAsDefault {
            UserDefaults.standard.set(style, forKey: SettingsKeys.defaultNotesStyle)
        }

        // Przy regeneracji zapisanego wykładu w pamięci zwykle nie ma już zrzutów —
        // wczytujemy je z dysku, żeby nowa wersja notatek ich nie zgubiła.
        let shots = attachedImages.isEmpty ? savedShotsAsAttachments(for: lecture) : attachedImages
        let context = attachmentContext

        do {
            phase = .generatingNotes
            let md = try await makeNotes(
                transcript: rawTranscript, course: lecture.course, title: lecture.title,
                date: lecture.date, shots: shots, style: style, imageContext: context
            )
            // Trzymamy tylko jedną wersję notatek (`<baza>.md`) — stare wersje usuwamy,
            // żeby pliki notatek nie narastały z każdą regeneracją.
            let mdURL = try storage.saveNotes(md, course: lecture.course, title: lecture.title, date: lecture.date, version: 1)
            for old in lecture.notesPaths where old != mdURL.path {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: old))
            }
            lecture.notesPaths = [mdURL.path]
            lecture.usedStyle = style
            try? modelContext?.save()
            if selectedLecture === lecture { notesMarkdown = md }
            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// Wczytuje z dysku zapisane zrzuty wykładu jako załączniki (do regeneracji notatek),
    /// z czasem z `_meta.json`, żeby trafiły we właściwe miejsca.
    private func savedShotsAsAttachments(for lecture: Lecture) -> [AttachedImage] {
        storage.loadScreenshots(course: lecture.course, title: lecture.title, date: lecture.date)
            .compactMap { shot in
                guard let data = try? Data(contentsOf: shot.url), let image = NSImage(data: data) else { return nil }
                var item = AttachedImage(image: image, data: data, timestamp: shot.time ?? 0)
                item.savedURL = shot.url
                item.assetFilename = shot.url.lastPathComponent
                return item
            }
    }

    /// Trwale usuwa zapisany zrzut z dysku, z notatek (link `![…](plik)`) i z metadanych.
    func deleteSavedScreenshot(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        let filename = url.lastPathComponent

        if !notesMarkdown.isEmpty {
            let kept = notesMarkdown.components(separatedBy: "\n").filter { line in
                !(line.contains("](") && line.contains(filename))
            }
            let newMarkdown = kept.joined(separator: "\n")
            if newMarkdown != notesMarkdown {
                notesMarkdown = newMarkdown
                persistCurrentNotes()
            }
        }
        if let lec = selectedLecture {
            let remaining = storage.loadScreenshots(course: lec.course, title: lec.title, date: lec.date)
                .filter { $0.url.lastPathComponent != filename }
                .map { (file: $0.url.lastPathComponent, time: $0.time ?? 0) }
            storage.saveScreenshotMetaEntries(remaining, course: lec.course, title: lec.title, date: lec.date)
        }
        galleryRefresh += 1
    }

    // MARK: - Eksport notatek

    /// Eksport „Markdown + obrazy" do wybranego folderu (edytowalne w dowolnym edytorze MD).
    func exportNotesMarkdownBundle() {
        guard let lec = selectedLecture, let mdPath = lec.latestNotesPath else { return }
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.prompt = "Eksportuj tutaj"
        guard open.runModal() == .OK, let dest = open.url else { return }

        let fm = FileManager.default
        let safeTitle = storage.sanitize(lec.title)
        let exportDir = dest.appendingPathComponent(safeTitle, isDirectory: true)
        try? fm.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let destMD = exportDir.appendingPathComponent("\(safeTitle).md")
        try? fm.removeItem(at: destMD)
        try? fm.copyItem(at: URL(fileURLWithPath: mdPath), to: destMD)

        // Skopiuj folder obrazów (linki w .md wskazują na `<baza>.assets/…`).
        let assetsName = "\(storage.fileBase(title: lec.title, date: lec.date)).assets"
        let assets = storage.notesDirectory(course: lec.course).appendingPathComponent(assetsName)
        if fm.fileExists(atPath: assets.path) {
            let destAssets = exportDir.appendingPathComponent(assetsName)
            try? fm.removeItem(at: destAssets)
            try? fm.copyItem(at: assets, to: destAssets)
        }
        NSWorkspace.shared.activateFileViewerSelecting([exportDir])
    }

    /// Eksport sformatowanej notatki (z obrazami) do PDF.
    func exportNotesPDF() {
        guard !notesMarkdown.isEmpty else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = "\(selectedLecture?.title ?? "notatki").pdf"
        save.allowedContentTypes = [.pdf]
        guard save.runModal() == .OK, let url = save.url else { return }

        let content = MarkdownView(markdown: notesMarkdown, baseURL: notesBaseURL)
            .padding(28)
            .frame(width: 612, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: content)
        renderer.render { size, renderInContext in
            var box = CGRect(x: 0, y: 0, width: size.width, height: max(size.height, 1))
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            renderInContext(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Buduje notatki jako tekst sformatowany (z obrazami) — do wklejenia/udostępnienia
    /// np. do Apple Notes.
    func notesRichText() -> NSAttributedString? {
        guard !notesMarkdown.isEmpty else { return nil }
        return NotesRichText.attributed(markdown: notesMarkdown, baseURL: notesBaseURL)
    }

    /// Kopiuje notatki (tekst + obrazy) do schowka jako RTFD — wklejenie (⌘V) do Apple Notes
    /// zachowuje formatowanie i zrzuty ekranu.
    func copyNotesAsRichText() {
        guard let attr = notesRichText() else { return }
        let range = NSRange(location: 0, length: attr.length)
        let pb = NSPasteboard.general
        pb.declareTypes([.rtfd, .rtf, .string], owner: nil)
        if let rtfd = attr.rtfd(from: range,
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
            pb.setData(rtfd, forType: .rtfd)
        }
        if let rtf = attr.rtf(from: range,
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pb.setData(rtf, forType: .rtf)
        }
        pb.setString(attr.string, forType: .string)
    }

    /// Ustawia szerokość obrazu w notatkach (procent szerokości kolumny) i zapisuje zmianę.
    /// Zapis jako tytuł obrazu Markdown: `![opis](plik "NN")` (100% = bez tytułu).
    func setNoteImageWidth(path: String, percent: Int) {
        guard !notesMarkdown.isEmpty else { return }
        let needle = "](\(path)"
        var changed = false
        let newLines = notesMarkdown.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("!["), t.contains(needle),
                  let sep = t.range(of: "](") else { return line }
            let alt = String(t[t.index(t.startIndex, offsetBy: 2)..<sep.lowerBound])
            changed = true
            return percent >= 100 ? "![\(alt)](\(path))" : "![\(alt)](\(path) \"\(percent)\")"
        }
        guard changed else { return }
        notesMarkdown = newLines.joined(separator: "\n")
        persistCurrentNotes()
        // Bez galleryRefresh — to tylko zmiana szerokości; pełne przebudowanie powodowałoby skok.
    }

    /// Nadpisuje na dysku najnowszą wersję notatek bieżącą zawartością `notesMarkdown`.
    private func persistCurrentNotes() {
        guard let lec = selectedLecture, !notesMarkdown.isEmpty else { return }
        let version = max(1, lec.notesPaths.count)
        if let url = try? storage.saveNotes(notesMarkdown, course: lec.course, title: lec.title,
                                            date: lec.date, version: version) {
            if lec.notesPaths.isEmpty { lec.notesPaths = [url.path] }
            try? modelContext?.save()
        }
    }

    /// Pokaż w Finderze pliki wykładu: folder ze zrzutami (jeśli są), inaczej folder kursu.
    func revealLectureFiles() {
        guard let lec = selectedLecture else { return }
        let fm = FileManager.default
        let assetsName = "\(storage.fileBase(title: lec.title, date: lec.date)).assets"
        let assets = storage.notesDirectory(course: lec.course).appendingPathComponent(assetsName)
        if fm.fileExists(atPath: assets.path) {
            NSWorkspace.shared.activateFileViewerSelecting([assets])
            return
        }
        // Brak zrzutów — pokaż katalog kursu (audio/transkrypty/notatki).
        let courseDir = storage.courseDirectory(lec.course)
        if fm.fileExists(atPath: courseDir.path) {
            NSWorkspace.shared.open(courseDir)
        }
    }

    // MARK: - Oszczędzanie miejsca na dysku

    /// Czy zachowywać pliki audio po przetworzeniu (domyślnie NIE — oszczędza miejsce).
    private var keepAudioFiles: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.keepAudio) }

    /// Usuwa wskazane pliki audio (o ile użytkownik nie chce ich zachowywać) i czyści ścieżkę.
    private func cleanupAudio(_ paths: [String?], clearOn lecture: Lecture? = nil) {
        guard !keepAudioFiles else { return }
        let fm = FileManager.default
        for path in paths.compactMap({ $0 }) {
            try? fm.removeItem(at: URL(fileURLWithPath: path))
        }
        lecture?.audioPath = nil
    }

    /// Usuwa wykład wraz ze WSZYSTKIMI jego plikami (audio, transkrypt, notatki, zrzuty).
    func deleteLecture(_ lecture: Lecture) {
        deleteLectureFiles(lecture)
        if selectedLecture === lecture { newSession() }
        modelContext?.delete(lecture)
        try? modelContext?.save()
    }

    private func deleteLectureFiles(_ lecture: Lecture) {
        let fm = FileManager.default
        if let p = lecture.audioPath { try? fm.removeItem(at: URL(fileURLWithPath: p)) }
        if let p = lecture.transcriptPath { try? fm.removeItem(at: URL(fileURLWithPath: p)) }
        for p in lecture.notesPaths { try? fm.removeItem(at: URL(fileURLWithPath: p)) }
        try? fm.removeItem(at: storage.assetsDirectory(course: lecture.course,
                                                       title: lecture.title, date: lecture.date))
    }

    /// Usuwa wszystkie pliki audio (z wpisów i osierocone) — ręczne zwolnienie miejsca.
    @discardableResult
    func deleteAllAudioFiles() -> Int {
        let fm = FileManager.default
        var removed = 0
        if let ctx = modelContext, let all = try? ctx.fetch(FetchDescriptor<Lecture>()) {
            for lec in all where lec.audioPath != nil {
                if let p = lec.audioPath, fm.fileExists(atPath: p) {
                    try? fm.removeItem(at: URL(fileURLWithPath: p)); removed += 1
                }
                lec.audioPath = nil
            }
            try? ctx.save()
        }
        // Osierocone pliki .caf (kontynuacje, sesje trybu auto) w folderach audio.
        if let courses = try? fm.contentsOfDirectory(at: storage.baseDirectory, includingPropertiesForKeys: nil) {
            for course in courses {
                let audioDir = course.appendingPathComponent("audio", isDirectory: true)
                if let files = try? fm.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil) {
                    for file in files where file.pathExtension.lowercased() == "caf" {
                        try? fm.removeItem(at: file); removed += 1
                    }
                }
            }
        }
        return removed
    }

    // MARK: - Historia / nowa sesja

    func select(_ lecture: Lecture) {
        guard !isRecording else { return }
        continuationLecture = nil
        selectedLecture = lecture
        activeLecture = nil
        rawTranscript = lecture.transcriptPath.flatMap { storage.readText(at: $0) } ?? ""
        notesMarkdown = lecture.latestNotesPath.flatMap { storage.readText(at: $0) } ?? ""
        clearAttachments()
        recordPanelCollapsed = true   // oglądanie wykładu → notatki na pierwszym planie
        phase = lecture.transcriptPath == nil ? .idle : .done
    }

    func newSession() {
        guard !isRecording else { return }
        continuationLecture = nil
        selectedLecture = nil
        activeLecture = nil
        rawTranscript = ""
        notesMarkdown = ""
        clearAttachments()
        recordPanelCollapsed = false   // nowe nagranie → rozwiń ustawienia
        phase = .idle
    }

    private var notesModel: String {
        let stored = UserDefaults.standard.string(forKey: SettingsKeys.notesModel) ?? ""
        return stored.isEmpty ? "claude-sonnet-4-6" : stored
    }
}

/// Załączony zrzut ekranu (do dołączenia do generowania notatek).
struct AttachedImage: Identifiable {
    let id = UUID()
    let image: NSImage
    let data: Data   // skompresowane dane obrazu (JPEG, czasem PNG)
    var timestamp: TimeInterval = 0   // czas w wykładzie/sesji, w którym zrobiono zrzut
    var savedURL: URL?               // plik na dysku (zapisany od razu przy zrobieniu zrzutu)
    var assetFilename: String?       // nazwa pliku w folderze assets wykładu
}

extension NSImage {
    func pngDataRepresentation() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Wykryty segment (kandydat na wykład) do korekty w UI przed przetworzeniem.
struct ReviewSegment: Identifiable, Equatable {
    let id = UUID()
    var start: Double
    var duration: Double
    var title: String
    var preview: String = ""
    var previewLoading: Bool = false

    var end: Double { start + duration }
    var range: SilenceSegmenter.TimeRange { .init(start: start, duration: duration) }
}
