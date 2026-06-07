import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    @AppStorage(SettingsKeys.notesModel) private var notesModel = "claude-sonnet-4-6"
    @AppStorage(SettingsKeys.transcriptionModelVariant) private var transcriptionVariant = ""
    @AppStorage(SettingsKeys.storageFolderPath) private var storageFolderPath = ""
    @AppStorage(SettingsKeys.autoMinSilence) private var autoMinSilence = 4.0
    @AppStorage(SettingsKeys.autoSilenceThreshold) private var autoSilenceThreshold = 0.02
    @AppStorage(SettingsKeys.autoMinSegment) private var autoMinSegment = 30.0
    @AppStorage(SettingsKeys.liveTranscription) private var liveTranscription = false
    @AppStorage(SettingsKeys.keepAudio) private var keepAudio = false
    @AppStorage(SettingsKeys.embedOldScreenshots) private var embedOldScreenshots = true

    @State private var availableModels: [String] = []
    @State private var recommendedDefault = ""
    @State private var loadingModels = false
    @State private var audioCleanupInfo = ""
    @State private var report: StorageReport?
    @State private var storageInfo = ""

    private let notesModels = ["claude-sonnet-4-6", "claude-opus-4-7"]

    var body: some View {
        Form {
            apiKeySection
            transcriptionSection
            notesSection
            autoModeSection
            screenshotSection
            memorySection
            storageSection
        }
        .formStyle(.grouped)
        .padding(20)
        .task {
            recommendedDefault = TranscriptionEngine.recommendedDefaultVariant()
            report = appModel.storageReport()
        }
    }

    // MARK: - Pamięć (zajętość dysku)

    private var memorySection: some View {
        Section("Pamięć — co ile zajmuje") {
            if let r = report {
                storageRow("Notatki", r.notesBytes, "doc.text")
                storageRow("Transkrypcje", r.transcriptsBytes, "text.alignleft")
                storageRow("Zrzuty ekranu", r.screenshotsBytes, "photo.on.rectangle")
                storageRow("Nagrania audio", r.audioBytes, "waveform")
                storageRow("Modele transkrypcji", r.modelsBytes, "cpu")
                Divider()
                HStack {
                    Text("Razem").font(.headline)
                    Spacer()
                    Text(StorageReport.format(r.totalBytes)).font(.headline.monospacedDigit())
                }

                if r.models.count > 1 {
                    DisclosureGroup("Modele (\(r.models.count)) — szczegóły") {
                        ForEach(r.models) { m in
                            HStack {
                                Image(systemName: m.isActive ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(m.isActive ? .green : .secondary).font(.caption)
                                Text(m.name).font(.caption).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(StorageReport.format(m.bytes)).font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack {
                    Button("Usuń nieużywane modele") {
                        let n = appModel.deleteUnusedModels()
                        storageInfo = n == 0 ? "Brak modeli do usunięcia." : "Usunięto modeli: \(n)."
                        report = appModel.storageReport()
                    }
                    .disabled(r.models.filter { !$0.isActive }.isEmpty)
                    Spacer()
                    Button("Odśwież") { report = appModel.storageReport() }
                }
                if !storageInfo.isEmpty {
                    Text(storageInfo).font(.caption).foregroundStyle(.green)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Liczę…").foregroundStyle(.secondary) }
            }
            Text("Aplikacja trzyma notatki w ~/Navoica, a modele w Application Support. Audio jest kasowane po przetworzeniu (chyba że je zachowujesz poniżej).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func storageRow(_ title: String, _ bytes: Int64, _ icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(StorageReport.format(bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // MARK: - Klucz API

    private var apiKeySection: some View {
        Section("Anthropic API") {
            APIKeyEditor()
            Text("Przycisk testuje połączenie i zapisuje klucz do Keychain dopiero po sukcesie. Klucz nie jest przechowywany w pliku ustawień ani w kodzie.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Model transkrypcji

    private var transcriptionSection: some View {
        Section("Model transkrypcji (WhisperKit)") {
            Picker("Model", selection: $transcriptionVariant) {
                Text("Domyślny dla urządzenia\(recommendedDefault.isEmpty ? "" : " (\(recommendedDefault))")")
                    .tag("")
                ForEach(availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }

            HStack {
                Button {
                    Task { await loadAvailableModels() }
                } label: {
                    Label("Pobierz listę modeli", systemImage: "arrow.clockwise")
                }
                .disabled(loadingModels)
                if loadingModels { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    Task { await appModel.transcription.prepare(variant: transcriptionVariant) }
                } label: {
                    Label("Pobierz / przeładuj wybrany", systemImage: "square.and.arrow.down")
                }
            }

            transcriptionStateLabel

            HStack {
                Button("Przywróć domyślny (turbo large-v3, ~0,6 GB)") {
                    transcriptionVariant = ""   // pusty = domyślny = zalecany turbo
                    Task { await appModel.transcription.ensureDownloaded(variant: nil) }
                }
                Spacer()
                Button("Lekki (małe RAM)") {
                    transcriptionVariant = TranscriptionEngine.memorySavingVariant()
                }
            }
            Text("Domyślnie używamy turbo large-v3: jakość bliska pełnego large-v3, a tylko ~0,6 GB RAM — dobry kompromis dla polskiego. Długie nagrania transkrybujemy kawałkami (cięcie w ciszy), więc zużycie pamięci jest STAŁE niezależnie od długości sesji — bezpiecznie na 8 GB. Nic nie musisz zmieniać.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Pamięć ≈ rozmiar modelu: tiny ~0,2 · base ~0,4 · small ~1 · turbo large-v3 ~0,6 · medium ~2–3 · large-v3 ~4–6 GB. Model jest w RAM tylko podczas transkrypcji i zwalniany zaraz po.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Transkrypcja na żywo (w trakcie nagrywania)", isOn: $liveTranscription)
            Text("Domyślnie WYŁĄCZONE (zalecane). Włączona pokazuje tekst na bieżąco, ale trzyma model w pamięci przez całe nagranie — na wolniejszym Macu przy długim wykładzie może mocno obciążyć RAM. Wyłączona: transkrypt powstaje po zatrzymaniu, kawałkami z pliku, przy stałym, niskim zużyciu pamięci. Notatki AI i tak powstają dopiero po stopie.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var transcriptionStateLabel: some View {
        switch appModel.transcription.state {
        case .ready:
            Label("Model gotowy" + (appModel.transcription.loadedVariant.map { ": \($0)" } ?? ""),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case let .downloading(progress):
            ProgressView(value: progress) { Text("Pobieranie… \(Int(progress * 100))%").font(.caption) }
        case .loading:
            Label("Ładowanie modelu…", systemImage: "hourglass").font(.caption)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.caption)
        case .notLoaded:
            EmptyView()
        }
    }

    // MARK: - Model notatek

    private var notesSection: some View {
        Section("Model notatek (Claude)") {
            Picker("Model", selection: $notesModel) {
                ForEach(notesModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            Text("Sonnet: dobra jakość i koszt. Opus: maksymalna jakość.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Tryb automatyczny

    private var autoModeSection: some View {
        Section("Tryb automatyczny (segmentacja po ciszy)") {
            VStack(alignment: .leading) {
                Text("Minimalny czas ciszy uznawany za przerwę: \(autoMinSilence, specifier: "%.1f") s")
                Slider(value: $autoMinSilence, in: 1...15, step: 0.5)
            }
            VStack(alignment: .leading) {
                Text("Próg ciszy (amplituda): \(autoSilenceThreshold, specifier: "%.3f")")
                Slider(value: $autoSilenceThreshold, in: 0.005...0.1)
                Text("Niżej = bardziej czuły (mniej ciszy uznawanej za przerwę). Różne wykłady mają różny poziom — kalibruj.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Text("Minimalna długość segmentu: \(Int(autoMinSegment)) s")
                Slider(value: $autoMinSegment, in: 10...120, step: 5)
                Text("Krótsze fragmenty są odrzucane jako szum/przerywniki.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Zrzuty ekranu (skróty globalne)

    private var screenshotSection: some View {
        Section("Zrzuty ekranu (skróty globalne)") {
            HStack {
                Text("Zrzut zaznaczonego obszaru")
                Spacer()
                Text("⌥⌘S").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Ustaw / zmień obszar zrzutu")
                Spacer()
                Text("⌥⌘R").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Ustaw obszar zrzutu teraz") { appModel.setScreenshotRegion() }
                Spacer()
                if appModel.hasScreenshotRegion {
                    Label("Obszar ustawiony", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                } else {
                    Label("Brak obszaru", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary).font(.caption)
                }
            }
            Text("Skróty działają globalnie — także gdy oglądasz kurs w innej aplikacji. Zrzut dolepia się do bieżącego nagrania z czasem, a AI wplata go w notatki we właściwym miejscu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Folder zapisu

    private var storageSection: some View {
        Section("Folder zapisu") {
            HStack {
                Text(displayPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Zmień…") { chooseFolder() }
                if !storageFolderPath.isEmpty {
                    Button("Domyślny") { storageFolderPath = "" }
                }
            }
            Text("Domyślnie: ~/Navoica. Struktura: <Kurs>/{audio, transkrypty, notatki}.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Zachowaj pliki audio po przetworzeniu", isOn: $keepAudio)
            Text("Domyślnie WYŁĄCZONE — po wygenerowaniu transkryptu i notatek nagranie audio jest usuwane (oszczędza dużo miejsca; notatki powstają z tekstu, nie z audio).")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Wtapiaj zrzuty w notatkę po 2 dniach", isOn: $embedOldScreenshots)
            Text("Po 2 dniach luźne pliki zrzutów są wtapiane bezpośrednio w plik notatki i kasowane z dysku — zdjęcia zostają w notatce, ale nie zajmują miejsca jako osobne pliki.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Usuń teraz wszystkie pliki audio") {
                    let removed = appModel.deleteAllAudioFiles()
                    audioCleanupInfo = removed == 0
                        ? "Brak plików audio do usunięcia."
                        : "Usunięto plików audio: \(removed)."
                }
                Spacer()
                if !audioCleanupInfo.isEmpty {
                    Text(audioCleanupInfo).font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    private var displayPath: String {
        storageFolderPath.isEmpty
            ? "~/Navoica (domyślny)"
            : storageFolderPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Wybierz"
        if panel.runModal() == .OK, let url = panel.url {
            storageFolderPath = url.path
        }
    }

    private func loadAvailableModels() async {
        loadingModels = true
        let result = await TranscriptionEngine.availableModels()
        recommendedDefault = result.default
        availableModels = result.supported
        loadingModels = false
    }
}
