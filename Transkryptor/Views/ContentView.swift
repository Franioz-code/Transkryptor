import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Query(sort: [SortDescriptor(\Lecture.date, order: .reverse)]) private var lectures: [Lecture]

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView {
            SidebarView(lectures: lectures)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            DetailView()
        }
        .sheet(isPresented: $appModel.showingSegmentReview) {
            SegmentReviewView()
        }
        .sheet(isPresented: $appModel.showingWindowPicker) {
            WindowPickerView { window in
                appModel.recordWindowID = window.windowID
                appModel.recordWindowName = window.title.isEmpty
                    ? window.appName : "\(window.appName) — \(window.title)"
                appModel.recordAppPID = nil
            }
        }
        .sheet(isPresented: $appModel.showingShortcuts) { ShortcutsView() }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    let lectures: [Lecture]
    @Environment(AppModel.self) private var appModel
    @State private var selection: Lecture?

    private var grouped: [(course: String, items: [Lecture])] {
        Dictionary(grouping: lectures, by: \.course)
            .map { (course: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.course.localizedCaseInsensitiveCompare($1.course) == .orderedAscending }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(grouped, id: \.course) { group in
                Section(group.course) {
                    ForEach(group.items) { lecture in
                        LectureRow(lecture: lecture)
                            .tag(lecture)
                            .contextMenu {
                                if lecture.transcriptPath != nil {
                                    Button {
                                        appModel.beginContinuation(lecture)
                                    } label: {
                                        Label("Kontynuuj wykład", systemImage: "mic.badge.plus")
                                    }
                                    .disabled(appModel.isRecording)
                                }
                                Button(role: .destructive) {
                                    appModel.deleteLecture(lecture)
                                } label: {
                                    Label("Usuń wykład", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { offsets in delete(group.items, at: offsets) }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Transkryptor")
        .overlay {
            if lectures.isEmpty {
                ContentUnavailableView(
                    "Brak wykładów",
                    systemImage: "waveform",
                    description: Text("Wybierz tryb i nagraj pierwszy wykład w panelu po prawej.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selection = nil
                    appModel.newSession()
                } label: {
                    Label("Nowe nagranie", systemImage: "plus")
                }
                .disabled(appModel.isRecording)
                .help("Wyczyść panele i przygotuj nowe nagranie")
            }
            ToolbarItem(placement: .automatic) {
                Button { appModel.showingShortcuts = true } label: {
                    Label("Skróty", systemImage: "keyboard")
                }
                .help("Ściągawka skrótów klawiszowych")
            }
        }
        .onChange(of: selection) { _, newValue in
            if let newValue { appModel.select(newValue) }
        }
        .onChange(of: appModel.selectedLecture) { _, newValue in
            if selection !== newValue { selection = newValue }
        }
    }

    private func delete(_ items: [Lecture], at offsets: IndexSet) {
        for index in offsets {
            appModel.deleteLecture(items[index])   // usuwa też pliki z dysku
        }
    }
}

private struct LectureRow: View {
    let lecture: Lecture

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(lecture.title)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 6) {
                Image(systemName: lecture.mode == .singleApp ? "app.badge" : "speaker.wave.2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(lecture.date, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            if let cont = appModel.continuationLecture {
                ContinuationBanner(title: cont.title)
                Divider()
            }
            if appModel.recordPanelCollapsed {
                CollapsedRecordBar()
            } else {
                // RecordPanelView raportuje wysokość ~0 obok zachłannego ResultsView,
                // więc górę trzymamy na jawnej wysokości (ScrollView gwarantuje brak ucinania).
                ScrollView {
                    VStack(spacing: 0) {
                        RecordPanelView()
                        Divider()
                        StatusBar()
                    }
                }
                .frame(height: 430)
                .background(.bar)
            }

            Divider()

            ResultsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pasek informujący, że trwa konfiguracja kontynuacji wcześniejszego wykładu.
private struct ContinuationBanner: View {
    @Environment(AppModel.self) private var appModel
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.badge.plus").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Kontynuujesz: \(title)")
                    .font(.callout.weight(.medium)).lineLimit(1)
                Text("Wybierz źródło dźwięku i naciśnij Start — nowy fragment doklei się do transkrypcji, a notatki przeliczą się od nowa.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Anuluj") { appModel.cancelContinuation() }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

/// Cienki pasek, gdy ustawienia są zwinięte — szybkie sterowanie + rozwinięcie.
private struct CollapsedRecordBar: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(appModel.isRecording ? (appModel.isPaused ? Color.yellow : Color.red) : Color.secondary)
                .frame(width: 9, height: 9)
            Text(appModel.phase.label)
                .font(.callout.weight(.medium)).lineLimit(1)
            if appModel.phase.isBusy { ProgressView().controlSize(.small) }
            Spacer()
            if appModel.isRecording {
                Button(role: .destructive) { appModel.stopFromIndicator() } label: {
                    Label(appModel.isAutoMode ? "Zakończ" : "Stop", systemImage: "stop.fill")
                }
                Button { appModel.togglePause() } label: {
                    Image(systemName: appModel.isPaused ? "play.fill" : "pause.fill")
                }
            } else {
                Button { Task { await appModel.startConfiguredRecording() } } label: {
                    Label(appModel.isAutoMode ? "Rozpocznij sesję" : "Nagraj", systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(!appModel.canStartRecording)
            }
            Button { withAnimation { appModel.recordPanelCollapsed = false } } label: {
                Label("Ustawienia", systemImage: "chevron.down")
            }
            .help("Rozwiń ustawienia nagrywania")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }
}

private struct StatusBar: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: 10) {
            phaseIcon
            Text(appModel.phase.label)
                .font(.callout.weight(.medium))
                .foregroundStyle(isError ? Color.red : .primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !appModel.statusDetail.isEmpty {
                Text(appModel.statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if appModel.phase.isBusy {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button { withAnimation { appModel.recordPanelCollapsed = true } } label: {
                Label("Zwiń", systemImage: "chevron.up")
            }
            .help("Zwiń ustawienia — więcej miejsca na notatki")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var isError: Bool {
        if case .error = appModel.phase { return true }
        return false
    }

    @ViewBuilder private var phaseIcon: some View {
        switch appModel.phase {
        case .idle:            Image(systemName: "circle").foregroundStyle(.secondary)
        case .recording:       Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .segmenting:      Image(systemName: "scissors").foregroundStyle(.blue)
        case .transcribing:    Image(systemName: "waveform").foregroundStyle(.blue)
        case .generatingNotes: Image(systemName: "sparkles").foregroundStyle(.purple)
        case .done:            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .notesBlocked:    Image(systemName: "key.slash").foregroundStyle(.orange)
        case .error:           Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
