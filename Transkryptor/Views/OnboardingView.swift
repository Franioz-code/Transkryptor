import SwiftUI
import AppKit

/// Prosty, krokowy onboarding dla nowych użytkowników.
struct OnboardingView: View {
    @AppStorage(SettingsKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(SettingsKeys.transcriptionModelVariant) private var modelVariant = ""
    @Environment(AppModel.self) private var appModel

    @State private var step = 0
    private let stepCount = 4

    private var engine: TranscriptionEngine { appModel.transcription }

    var body: some View {
        VStack(spacing: 0) {
            progressHeader
            Divider()

            ScrollView {
                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: permissionStep
                    case 2: modelStep
                    default: apiKeyStep
                    }
                }
                .padding(28)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }

            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Nagłówek / stopka

    private var progressHeader: some View {
        HStack(spacing: 10) {
            Label("Transkryptor wykładów", systemImage: "waveform.badge.mic")
                .font(.headline)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            Text("Krok \(step + 1) z \(stepCount)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Wstecz") { withAnimation { step -= 1 } }
            }
            Spacer()
            if step < stepCount - 1 {
                Button("Dalej") { withAnimation { step += 1 } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Zacznij korzystać") { hasCompletedOnboarding = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!engine.isReady)
            }
        }
        .padding(20)
    }

    // MARK: - Krok 0: powitanie

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Witaj!")
                .font(.largeTitle.bold())
            Text("Transkryptor nagrywa dźwięk z aplikacji lub całego systemu, transkrybuje wykład po polsku lokalnie na Twoim Macu i tworzy z niego notatki w stylu podręcznika.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                bullet("mic.slash", "Mikrofon nie jest nigdy nagrywany — tylko dźwięk z komputera.")
                bullet("lock.laptopcomputer", "Transkrypcja działa offline (WhisperKit). Płacisz tylko za notatki AI.")
                bullet("doc.on.doc", "Dostajesz dwie wersje: surową transkrypcję i notatki, z możliwością kopiowania.")
                bullet("waveform.path", "Tryb automatyczny dzieli długą sesję na osobne wykłady.")
            }

            Text("W kolejnych krokach: zgoda na nagrywanie ekranu, pobranie modelu i (opcjonalnie) klucz API.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
    }

    // MARK: - Krok 1: uprawnienie

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uprawnienie: Nagrywanie ekranu")
                .font(.title2.bold())
            Text("Do przechwytywania dźwięku ScreenCaptureKit wymaga zgody na Nagrywanie ekranu, mimo że zapisujemy wyłącznie dźwięk — obraz ekranu nie jest zapisywany.")
                .foregroundStyle(.secondary)
            Text("Kliknij poniżej i zezwól. Jeśli monit się nie pojawi (zdarza się przy buildach niepodpisanych), dodaj aplikację ręcznie w Ustawieniach systemowych.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Poproś o zgodę / sprawdź") {
                    Task { await appModel.capture.refreshAvailableApps() }
                }
                .buttonStyle(.borderedProminent)
                Button("Otwórz Ustawienia systemowe") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    // MARK: - Krok 2: model

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Model transkrypcji")
                .font(.title2.bold())
            Text("Pobierz model WhisperKit — to jednorazowe. Transkrypcja działa potem lokalnie i offline.")
                .foregroundStyle(.secondary)

            modelStateView

            Button {
                Task { await engine.prepare(variant: modelVariant) }
            } label: {
                Label(downloadButtonTitle, systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPreparing)

            if engine.isReady {
                Text("Możesz przejść dalej.").font(.callout).foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder private var modelStateView: some View {
        switch engine.state {
        case .notLoaded:
            Text("Model nie jest jeszcze pobrany.").font(.callout).foregroundStyle(.secondary)
        case let .downloading(progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text("Pobieranie modelu… \(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Ładowanie modelu…").font(.callout) }
        case .ready:
            Label("Model gotowy do pracy.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
        }
    }

    private var isPreparing: Bool {
        switch engine.state {
        case .downloading, .loading: return true
        default: return false
        }
    }

    private var downloadButtonTitle: String {
        switch engine.state {
        case .ready:  return "Pobierz ponownie"
        case .failed: return "Spróbuj ponownie"
        default:      return "Pobierz model"
        }
    }

    // MARK: - Krok 3: klucz API

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Klucz Anthropic API (opcjonalnie)")
                .font(.title2.bold())
            Text("Potrzebny tylko do generowania notatek. Transkrypcja działa bez klucza — możesz dodać go później w Ustawieniach. Klucz jest testowany i zapisywany w Keychain dopiero po udanym połączeniu.")
                .foregroundStyle(.secondary)
            APIKeyEditor()

            if !engine.isReady {
                Label("Aby zakończyć, pobierz najpierw model transkrypcji (krok wstecz).",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }
}
