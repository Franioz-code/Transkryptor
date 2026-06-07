import Foundation

/// Zarządza magazynem na dane: ~/Navoica/<Kurs>/{audio,transkrypty,notatki}/
/// Zapisuje surową transkrypcję (.txt) i notatki (.md) z wersjonowaniem __vN.
struct StorageService {

    /// Katalog bazowy — domyślnie ~/Navoica, można nadpisać w ustawieniach.
    var baseDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: SettingsKeys.storageFolderPath),
           !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Navoica", isDirectory: true)
    }

    // MARK: - Katalogi

    func courseDirectory(_ course: String) -> URL {
        baseDirectory.appendingPathComponent(sanitize(course), isDirectory: true)
    }

    func subdirectory(_ name: String, course: String) -> URL {
        courseDirectory(course).appendingPathComponent(name, isDirectory: true)
    }

    @discardableResult
    func ensureDirectories(course: String) throws -> (audio: URL, transcripts: URL, notes: URL) {
        let audio = subdirectory("audio", course: course)
        let transcripts = subdirectory("transkrypty", course: course)
        let notes = subdirectory("notatki", course: course)
        for url in [audio, transcripts, notes] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return (audio, transcripts, notes)
    }

    // MARK: - Ścieżki plików

    func newAudioFileURL(course: String, title: String) throws -> URL {
        let dirs = try ensureDirectories(course: course)
        let stamp = Self.timestampFormatter.string(from: .now)
        return dirs.audio.appendingPathComponent("\(sanitize(title))-\(stamp).caf")
    }

    /// Plik ciągłej sesji trybu automatycznego (przed podziałem na segmenty).
    func newSessionFileURL(course: String) throws -> URL {
        let dirs = try ensureDirectories(course: course)
        let stamp = Self.timestampFormatter.string(from: .now)
        return dirs.audio.appendingPathComponent("_sesja-\(stamp).caf")
    }

    // MARK: - Zapis

    /// Unikalna baza nazwy pliku: `<tytuł>-<RRRR-MM-DD-GGMMSS>` z czasu sesji,
    /// żeby wykłady o tej samej nazwie się nie nadpisywały.
    func fileBase(title: String, date: Date) -> String {
        "\(sanitize(title))-\(Self.timestampFormatter.string(from: date))"
    }

    @discardableResult
    func saveTranscript(_ text: String, course: String, title: String, date: Date) throws -> URL {
        let dirs = try ensureDirectories(course: course)
        let url = dirs.transcripts.appendingPathComponent("\(fileBase(title: title, date: date)).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Zapisuje notatki. Wersja 1 -> `<baza>.md`, kolejne -> `<baza>__vN.md`,
    /// żeby nie nadpisać dobrej wersji.
    @discardableResult
    func saveNotes(_ markdown: String, course: String, title: String, date: Date, version: Int) throws -> URL {
        let dirs = try ensureDirectories(course: course)
        let base = fileBase(title: title, date: date)
        let filename = version <= 1 ? "\(base).md" : "\(base)__v\(version).md"
        let url = dirs.notes.appendingPathComponent(filename)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Katalog notatek danego kursu (do rozwiązywania ścieżek obrazków w podglądzie/eksporcie).
    func notesDirectory(course: String) -> URL {
        subdirectory("notatki", course: course)
    }

    /// Zapisuje obraz (zrzut/diagram/wzór) do folderu `<baza>.assets/` pod podaną nazwą.
    /// Zwraca ścieżkę względną (do wstawienia w Markdown jako `![…](…)`).
    @discardableResult
    func saveAssetImage(_ data: Data, name: String, course: String, title: String, date: Date) throws -> String {
        let dir = assetsDirectory(course: course, title: title, date: date)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name))
        return "\(fileBase(title: title, date: date)).assets/\(name)"
    }

    /// Folder ze zrzutami danego wykładu (`<baza>.assets/`).
    func assetsDirectory(course: String, title: String, date: Date) -> URL {
        notesDirectory(course: course)
            .appendingPathComponent("\(fileBase(title: title, date: date)).assets", isDirectory: true)
    }

    /// Zapisuje metadane zrzutów z jawnymi nazwami plików → czas. Pusta lista usuwa plik meta.
    func saveScreenshotMetaEntries(_ entries: [(file: String, time: TimeInterval)],
                                   course: String, title: String, date: Date) {
        let dir = assetsDirectory(course: course, title: title, date: date)
        let metaURL = dir.appendingPathComponent("_meta.json")
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: metaURL)
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let arr: [[String: Any]] = entries.map { ["file": $0.file, "time": $0.time] }
        if let data = try? JSONSerialization.data(withJSONObject: arr) {
            try? data.write(to: metaURL)
        }
    }

    /// Wczytuje zapisane zrzuty wykładu (posortowane wg nazwy = chronologicznie),
    /// dołączając czas z `_meta.json`, jeśli istnieje.
    func loadScreenshots(course: String, title: String, date: Date) -> [SavedScreenshot] {
        let dir = assetsDirectory(course: course, title: title, date: date)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let pngs = files
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased())
                && $0.lastPathComponent.hasPrefix("zrzut-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var times: [String: TimeInterval] = [:]
        if let data = try? Data(contentsOf: dir.appendingPathComponent("_meta.json")),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for e in arr {
                if let f = e["file"] as? String, let t = e["time"] as? Double { times[f] = t }
            }
        }
        return pngs.map { SavedScreenshot(url: $0, time: times[$0.lastPathComponent]) }
    }

    // MARK: - Odczyt

    func readText(at path: String) -> String? {
        try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    // MARK: - Raport zajętości dysku

    /// Rekurencyjny rozmiar katalogu w bajtach (0 gdy nie istnieje).
    func folderSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Sumuje rozmiar plików o danych rozszerzeniach w podkatalogu (np. „audio") każdego kursu.
    func sizeOfFiles(inSubdir subdir: String, extensions: Set<String>) -> Int64 {
        let fm = FileManager.default
        guard let courses = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else { return 0 }
        var total: Int64 = 0
        for course in courses {
            let dir = course.appendingPathComponent(subdir, isDirectory: true)
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { continue }
            for case let f as URL in en where extensions.contains(f.pathExtension.lowercased()) {
                let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                total += Int64(v?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Sumuje rozmiar folderów `*.assets` (zrzuty + wyrenderowane diagramy/wzory) we wszystkich kursach.
    func screenshotsSize() -> Int64 {
        let fm = FileManager.default
        guard let courses = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else { return 0 }
        var total: Int64 = 0
        for course in courses {
            let notes = course.appendingPathComponent("notatki", isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.pathExtension == "assets" {
                total += folderSize(item)
            }
        }
        return total
    }

    /// Bazowy katalog cache modeli WhisperKit (Application Support — poza TCC, zob. TranscriptionEngine).
    var modelsBaseDirectory: URL {
        TranscriptionEngine.modelsDownloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// Lista pobranych wariantów modeli z rozmiarami (do panelu pamięci).
    func modelVariants() -> [(name: String, url: URL, bytes: Int64)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: modelsBaseDirectory, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { (name: $0.lastPathComponent, url: $0, bytes: folderSize($0)) }
            .sorted { $0.bytes > $1.bytes }
    }

    // MARK: - Pomocnicze

    func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: illegal).joined(separator: "-")
        return cleaned.isEmpty ? "bez-nazwy" : cleaned
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
}

/// Zapisany na dysku zrzut ekranu wykładu (do galerii w aplikacji).
struct SavedScreenshot: Identifiable {
    var id: String { url.path }
    let url: URL
    let time: TimeInterval?
}

/// Klucze ustawień (UserDefaults) używane w całej aplikacji.
enum SettingsKeys {
    static let storageFolderPath = "storageFolderPath"
    static let defaultNotesStyle = "defaultNotesStyle"
    static let transcriptionModelVariant = "transcriptionModelVariant"
    static let notesModel = "notesModel"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let autoMinSilence = "autoMinSilence"
    static let autoSilenceThreshold = "autoSilenceThreshold"
    static let autoMinSegment = "autoMinSegment"
    static let liveTranscription = "liveTranscription"
    /// Czy zachowywać pliki audio po przetworzeniu (domyślnie NIE — oszczędza miejsce).
    static let keepAudio = "keepAudio"
    /// Czy po 2 dniach wtapiać zrzuty w notatkę i kasować luźne pliki (domyślnie TAK).
    static let embedOldScreenshots = "embedOldScreenshots"
}
