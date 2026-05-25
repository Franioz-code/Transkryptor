import SwiftUI
import AppKit

struct ResultsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var notesExpanded = false

    var body: some View {
        Group {
            if notesExpanded {
                notesPanel   // notatki na całą szerokość — główny content
            } else {
                HStack(spacing: 0) {
                    transcriptPanel.frame(maxWidth: .infinity)
                    Divider()
                    rightColumn.frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rightColumn: some View {
        VStack(spacing: 0) {
            notesPanel
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    AttachmentsView()
                    Divider()
                    StyleAdjustView()
                }
            }
            .frame(maxHeight: 360)
        }
    }

    // MARK: - Lewy panel: surowa transkrypcja

    private var transcriptPanel: some View {
        PanelContainer(title: "Surowa transkrypcja", copyText: appModel.rawTranscript) {
            if appModel.rawTranscript.isEmpty {
                EmptyPanelHint(text: "Surowa transkrypcja (WhisperKit) pojawi się tutaj — na żywo w trakcie nagrywania i po zatrzymaniu.")
            } else {
                TextEditor(text: .constant(appModel.rawTranscript))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
            }
        }
    }

    // MARK: - Prawy panel: notatki AI (Markdown)

    private var notesPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Notatki AI").font(.headline)
                if appModel.phase.isBusy {
                    ProgressView().controlSize(.small)
                    Text(appModel.phase == .generatingNotes ? "Generuję…" : appModel.phase.label)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !appModel.notesMarkdown.isEmpty {
                    Menu {
                        Section("Apple Notes") {
                            Button("Kopiuj (tekst + obrazy)") { appModel.copyNotesAsRichText() }
                        }
                        Section("Plik") {
                            Button("PDF…") { appModel.exportNotesPDF() }
                            Button("Markdown + obrazy…") { appModel.exportNotesMarkdownBundle() }
                        }
                        Divider()
                        Button("Pokaż pliki w Finderze") { appModel.revealLectureFiles() }
                    } label: {
                        Label("Pobierz", systemImage: "square.and.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    ShareNotesButton { appModel.notesRichText() }
                }
                Button { withAnimation { notesExpanded.toggle() } } label: {
                    Image(systemName: notesExpanded
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                }
                .help(notesExpanded ? "Zmniejsz" : "Powiększ na całe okno")
                CopyButton(text: appModel.notesMarkdown)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
            Divider()

            // Pasek postępu widoczny ZAWSZE podczas przetwarzania — także przy ponownym
            // generowaniu, gdy stare notatki wciąż są na ekranie. Licznik sekund = dowód życia.
            if appModel.phase.isBusy {
                GeneratingBar(phase: appModel.phase,
                              detail: appModel.statusDetail,
                              startedAt: appModel.processingStartedAt)
                Divider()
            }

            if appModel.notesMarkdown.isEmpty {
                if appModel.phase.isBusy {
                    GeneratingHint(phase: appModel.phase, detail: appModel.statusDetail)
                } else {
                    EmptyPanelHint(text: "Notatki w stylu podręcznika (ze zrzutami) pojawią się tutaj po wygenerowaniu. Powiększ na całe okno lub pobierz do PDF / Markdown.")
                }
            } else {
                ScrollView {
                    MarkdownView(markdown: appModel.notesMarkdown, baseURL: appModel.notesBaseURL,
                                 onResizeImage: { path, percent in
                                     appModel.setNoteImageWidth(path: path, percent: percent)
                                 })
                        .id(appModel.galleryRefresh)
                        .padding(notesExpanded ? 28 : 14)
                        .frame(maxWidth: notesExpanded ? 920 : .infinity, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

// MARK: - Kontener panelu z nagłówkiem i przyciskiem Kopiuj

struct PanelContainer<Content: View>: View {
    let title: String
    let copyText: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                CopyButton(text: copyText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Skopiowano" : "Kopiuj",
                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
        }
        .disabled(text.isEmpty)
        .foregroundStyle(copied ? Color.green : Color.accentColor)
    }
}

private struct EmptyPanelHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }
}

/// Cienki pasek nad treścią notatek — zawsze widoczny w trakcie przetwarzania,
/// z animowanym spinnerem i licznikiem sekund (od razu widać, że nic się nie zacięło).
private struct GeneratingBar: View {
    let phase: AppModel.Phase
    let detail: String
    let startedAt: Date?

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label).font(.callout.weight(.medium))
            if !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text("· \(seconds) s").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Możesz pracować dalej — działa w tle")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12))
    }

    private var label: String {
        switch phase {
        case .transcribing:    return "Transkrypcja w toku…"
        case .segmenting:      return "Dzielę sesję na wykłady…"
        case .generatingNotes: return "Generuję notatki AI…"
        default:               return phase.label
        }
    }
}

/// Widoczny wskaźnik postępu w panelu notatek, gdy trwa przetwarzanie wykładu.
private struct GeneratingHint: View {
    let phase: AppModel.Phase
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(phaseText).font(.headline)
            if !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Text("Możesz spokojnie pracować dalej — przetwarzanie działa w tle i nic go nie przerwie.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private var phaseText: String {
        switch phase {
        case .transcribing:    return "Transkrypcja w toku…"
        case .segmenting:      return "Dzielę sesję na wykłady…"
        case .generatingNotes: return "Generuję notatki AI…"
        default:               return phase.label
        }
    }
}
