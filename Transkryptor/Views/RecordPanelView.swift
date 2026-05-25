import SwiftUI
import Foundation
import CoreGraphics

/// Panel nagrywania — krok po kroku. Cała konfiguracja żyje w AppModel,
/// żeby notch i panel korzystały z tych samych ustawień.
struct RecordPanelView: View {
    @Environment(AppModel.self) private var appModel

    private var capture: AudioCaptureManager { appModel.capture }
    private var isRecording: Bool { capture.isRecording }

    var body: some View {
        @Bindable var model = appModel

        VStack(alignment: .leading, spacing: 18) {
            // ① Co nagrywać
            step(1, "Wybierz, co nagrywać") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $model.recordMode) {
                        ForEach(CaptureMode.allCases) { m in Text(modeTitle(m)).tag(m) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(isRecording)

                    Text("Pojedyncza aplikacja = czysty zapis tylko wybranego źródła (zalecane).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("Mikrofon nie jest nagrywany w żadnym przypadku.", systemImage: "mic.slash")
                        .font(.caption).foregroundStyle(.secondary)

                    if model.recordMode == .singleApp {
                        sourcePicker(model)
                    }
                }
            }

            // ② Nazwa i tryb
            step(2, model.isAutoMode ? "Nazwij kurs i tryb" : "Nazwij wykład i tryb") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: $model.isAutoMode) {
                            Text("Tryb automatyczny — jedna sesja, autopodział na wykłady")
                        }
                        .toggleStyle(.switch)
                        .disabled(isRecording)
                        Text("Nagrywaj kolejne wykłady jednym ciągiem; po sesji aplikacja podzieli nagranie po przerwach ciszy (z ręczną korektą).")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        LabeledField(label: "Kurs", text: $model.recordCourse, placeholder: "np. Mikroekonomia")
                        LabeledField(
                            label: model.isAutoMode ? "Prefiks nazw (opcjonalnie)" : "Wykład",
                            text: $model.recordTitle,
                            placeholder: model.isAutoMode ? "np. Mikroekonomia (numeracja auto)" : "np. Elastyczność popytu"
                        )
                    }
                }
            }

            // ③ Nagrywaj
            step(3, stepThreeTitle) {
                controls
            }
        }
        .padding(20)
        .disabled(appModel.phase.isBusy)
        .task {
            if capture.availableApps.isEmpty { await capture.refreshAvailableApps() }
        }
    }

    // MARK: - Źródło (tryb A): picker aplikacji + wybór okna

    private func sourcePicker(_ model: AppModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Aplikacja:", selection: $model.recordAppPID) {
                    Text("— wybierz —").tag(pid_t?.none)
                    ForEach(capture.availableApps) { app in
                        Text(app.name).tag(pid_t?.some(app.processID))
                    }
                }
                .frame(maxWidth: 300)
                .disabled(isRecording)
                .onChange(of: model.recordAppPID) { _, newValue in
                    if newValue != nil { model.recordWindowID = nil; model.recordWindowName = "" }
                }

                Button { Task { await capture.refreshAvailableApps() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Odśwież listę aplikacji")
                .disabled(isRecording)

                Button { appModel.requestWindowPicker() } label: {
                    Label("Wybierz okno graficznie…", systemImage: "macwindow.on.rectangle")
                }
                .disabled(isRecording)
            }

            if model.recordWindowID != nil {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                    Text("Wybrane okno: \(model.recordWindowName)").lineLimit(1)
                    Button {
                        model.recordWindowID = nil; model.recordWindowName = ""
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .disabled(isRecording)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sterowanie

    private var controls: some View {
        HStack(spacing: 16) {
            if isRecording {
                Button(role: .destructive) {
                    appModel.stopFromIndicator()
                } label: {
                    Label(appModel.isAutoMode ? "Zakończ sesję" : "Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
                .keyboardShortcut(".", modifiers: .command)

                Button { appModel.togglePause() } label: {
                    Label(appModel.isPaused ? "Wznów" : "Pauza",
                          systemImage: appModel.isPaused ? "play.fill" : "pause.fill")
                }
                .controlSize(.large)
                .keyboardShortcut("p", modifiers: .command)
            } else {
                Button {
                    Task { await appModel.startConfiguredRecording() }
                } label: {
                    Label(appModel.isAutoMode ? "Rozpocznij sesję" : "Start nagrywania",
                          systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!appModel.canStartRecording)
            }

            if isRecording {
                Text(timeString(capture.elapsed))
                    .font(.system(.title3, design: .monospaced)).monospacedDigit()
                if appModel.isAutoMode {
                    Label("Wykład \(capture.currentSegmentIndex)", systemImage: "number")
                        .font(.callout).foregroundStyle(.secondary)
                }
                LevelMeter(level: capture.audioLevel).frame(width: 140, height: 10)
            }
            Spacer()
        }
    }

    private var stepThreeTitle: String {
        if isRecording { return appModel.isPaused ? "Wstrzymano" : "Nagrywanie trwa" }
        return appModel.isAutoMode ? "Rozpocznij sesję" : "Rozpocznij nagrywanie"
    }

    private func step<Content: View>(
        _ number: Int, _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.accentColor).frame(width: 20, height: 20)
                    Text("\(number)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                }
                Text(title).font(.headline)
            }
            content().padding(.leading, 28)
        }
    }

    private func modeTitle(_ m: CaptureMode) -> String {
        switch m {
        case .singleApp: return "Tylko jedną aplikację (zalecane)"
        case .system:    return "Cały dźwięk komputera"
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Drobne komponenty

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
        }
    }
}

private struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(max(0, min(level, 1))))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }
}
