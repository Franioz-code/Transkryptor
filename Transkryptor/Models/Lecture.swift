import Foundation
import SwiftData

/// Tryb nagrywania dźwięku.
enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case singleApp   // Tryb A: tylko jedna aplikacja
    case system      // Tryb B: cały dźwięk systemowy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .singleApp: return "Tylko jedną aplikację"
        case .system:    return "Cały dźwięk komputera"
        }
    }
}

/// Metadane jednego wykładu — kurs, tytuł, data, ścieżki do plików i użyty styl.
@Model
final class Lecture {
    var id: UUID
    var course: String
    var title: String
    var date: Date
    var modeRaw: String

    /// Ścieżki względne do katalogu bazowego (~/Navoica) lub absolutne — patrz StorageService.
    var audioPath: String?
    var transcriptPath: String?
    /// Wszystkie wersje notatek, najstarsza pierwsza (`<Wyklad>.md`, `__v2.md`, ...).
    var notesPaths: [String]
    /// Styl użyty przy ostatniej generacji.
    var usedStyle: String
    var durationSeconds: Double

    init(
        course: String,
        title: String,
        mode: CaptureMode,
        date: Date = .now
    ) {
        self.id = UUID()
        self.course = course
        self.title = title
        self.date = date
        self.modeRaw = mode.rawValue
        self.audioPath = nil
        self.transcriptPath = nil
        self.notesPaths = []
        self.usedStyle = ""
        self.durationSeconds = 0
    }

    var mode: CaptureMode {
        get { CaptureMode(rawValue: modeRaw) ?? .singleApp }
        set { modeRaw = newValue.rawValue }
    }

    /// Najnowsza wersja notatek.
    var latestNotesPath: String? { notesPaths.last }
}
