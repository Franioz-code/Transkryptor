import SwiftUI
import AppKit

/// Geometria wskaźnika (liczona raz przy starcie sesji).
private struct NotchMetrics: Equatable {
    var notchWidth: CGFloat
    var flank: CGFloat
    var collapsedWidth: CGFloat
    var collapsedHeight: CGFloat
    var expandedWidth: CGFloat
    var expandedHeight: CGFloat
    var pinnedWidth: CGFloat
    var pinnedHeight: CGFloat
    var hasNotch: Bool
}

/// Stan rozwinięcia obserwowany przez widok SwiftUI.
@MainActor
@Observable
final class NotchUIState {
    var isExpanded = false
    /// Tryb „przypięty" — pełny panel ustawień (pola, wybór źródła) zostaje otwarty
    /// niezależnie od ruchu myszy, aż użytkownik kliknie Gotowe/Start.
    var pinned = false
}

/// Wskaźnik statusu sesji w stylu Dynamic Island: czarny „pill" rozszerzający notch
/// na boki, rozwijany w dół na hover. Hover sterowany pozycją kursora (bez pętli rozwijania).
/// Dodatkowo ikona w pasku menu jako pewna baza.
@MainActor
final class NotchStatusController: NSObject {
    private weak var appModel: AppModel?
    private let uiState = NotchUIState()

    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    private var metrics = NotchMetrics(notchWidth: 0, flank: 116, collapsedWidth: 230,
                                       collapsedHeight: 24, expandedWidth: 380,
                                       expandedHeight: 128, pinnedWidth: 440,
                                       pinnedHeight: 400, hasNotch: false)
    private var panelRect: CGRect = .zero
    private var collapsedHotRect: CGRect = .zero
    private var pinnedRect: CGRect = .zero
    private var pinnedApplied = false

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init()
    }

    // MARK: - Cykl życia

    func start() {
        layoutForCurrentScreen()
        setupStatusItem()
        setupPanelIfNeeded()
        uiState.isExpanded = false
        applyMouseInteractive(false)
        panel?.setFrame(panelRect, display: true)
        panel?.orderFrontRegardless()
        startTimer()
        updateStatusItemTitle()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        uiState.isExpanded = false
        panel?.orderOut(nil)
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    /// Chowa wskaźnik na czas zaznaczania obszaru (żeby nie zasłaniał ekranu) i wstrzymuje hover.
    func hideForOverlay() {
        uiState.pinned = false
        pinnedApplied = false
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    /// Przywraca wskaźnik po zaznaczeniu obszaru.
    func restoreAfterOverlay() {
        guard panel != nil else { return }
        uiState.isExpanded = false
        applyMouseInteractive(false)
        panel?.setFrame(panelRect, display: false)
        panel?.orderFrontRegardless()
        startTimer()
    }

    // MARK: - Geometria

    private func layoutForCurrentScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, 24)

        var notchWidth: CGFloat = 0
        var hasNotch = false
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, frame.width - left.width - right.width)
            hasNotch = notchWidth > 0
        }

        let flank: CGFloat = 116
        let collapsedWidth = hasNotch ? notchWidth + 2 * flank : 230
        let expandedWidth = max(collapsedWidth, 380)
        let collapsedHeight = menuBarHeight
        let expandedHeight = menuBarHeight + 168
        let pinnedWidth = max(expandedWidth, 460)
        let pinnedHeight = menuBarHeight + 380

        metrics = NotchMetrics(notchWidth: notchWidth, flank: flank,
                               collapsedWidth: collapsedWidth, collapsedHeight: collapsedHeight,
                               expandedWidth: expandedWidth, expandedHeight: expandedHeight,
                               pinnedWidth: pinnedWidth, pinnedHeight: pinnedHeight,
                               hasNotch: hasNotch)

        let centerX = frame.midX
        let top = frame.maxY
        panelRect = CGRect(x: centerX - expandedWidth / 2, y: top - expandedHeight,
                           width: expandedWidth, height: expandedHeight)
        collapsedHotRect = CGRect(x: centerX - collapsedWidth / 2, y: top - collapsedHeight,
                                  width: collapsedWidth, height: collapsedHeight)
        pinnedRect = CGRect(x: centerX - pinnedWidth / 2, y: top - pinnedHeight,
                            width: pinnedWidth, height: pinnedHeight)
    }

    // MARK: - Panel

    private func setupPanelIfNeeded() {
        if let panel { panel.setFrame(panelRect, display: false); return }

        let panel = KeyableNotchPanel(
            contentRect: panelRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        let content = NotchIslandView(uiState: uiState, metrics: metrics)
            .environment(appModel ?? AppModel())
        panel.contentView = NSHostingView(rootView: AnyView(content))
        self.panel = panel
    }

    private func applyMouseInteractive(_ interactive: Bool) {
        // Gdy zwinięty — klik przelatuje (nie blokujemy paska menu). Gdy rozwinięty — przyjmuje kliki (przyciski).
        panel?.ignoresMouseEvents = !interactive
    }

    private func setExpanded(_ expanded: Bool) {
        guard uiState.isExpanded != expanded else { return }
        uiState.isExpanded = expanded
        applyMouseInteractive(expanded)
    }

    // MARK: - Pętla (hover wg pozycji myszy + tytuł w pasku menu)

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        // Tryb przypięty: panel powiększony i interaktywny, NIE zwija się od ruchu myszy.
        if uiState.pinned {
            if !pinnedApplied {
                pinnedApplied = true
                uiState.isExpanded = true
                panel?.ignoresMouseEvents = false
                panel?.setFrame(pinnedRect, display: true)
                // Aktywuj apkę i uczyń panel kluczowym, żeby pola tekstowe przyjmowały wpisywanie.
                NSApp.activate(ignoringOtherApps: true)
                panel?.makeKeyAndOrderFront(nil)
            }
            updateStatusItemTitle()
            return
        }
        if pinnedApplied {
            pinnedApplied = false
            panel?.setFrame(panelRect, display: true)
        }

        let mouse = NSEvent.mouseLocation
        // Histereza: rozwiń, gdy kursor wejdzie w pigułkę; zwiń dopiero, gdy opuści cały panel.
        let target = uiState.isExpanded ? panelRect.contains(mouse) : collapsedHotRect.contains(mouse)
        if target != uiState.isExpanded {
            setExpanded(target)
        }
        updateStatusItemTitle()
    }

    // MARK: - Ikona w pasku menu

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "●"

        let menu = NSMenu()
        let stopItem = NSMenuItem(title: "Zakończ nagrywanie", action: #selector(stopClicked), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)
        let pauseItem = NSMenuItem(title: "Pauza / Wznów", action: #selector(pauseClicked), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        let showItem = NSMenuItem(title: "Pokaż okno aplikacji", action: #selector(showWindowClicked), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        item.menu = menu
        self.statusItem = item
    }

    private func updateStatusItemTitle() {
        guard let appModel, appModel.isRecording else {
            statusItem?.button?.title = "●"
            return
        }
        let time = Self.timeString(appModel.capture.elapsed)
        let pausePrefix = appModel.isPaused ? "⏸ " : ""
        if appModel.capture.currentSegmentIndex > 0 {
            statusItem?.button?.title = "\(pausePrefix)● \(time) · \(appModel.capture.currentSegmentIndex)"
        } else {
            statusItem?.button?.title = "\(pausePrefix)● \(time)"
        }
    }

    @objc private func stopClicked() { appModel?.stopFromIndicator() }
    @objc private func pauseClicked() { appModel?.togglePause() }
    @objc private func showWindowClicked() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
    }

    static func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Widok wyspy (SwiftUI)

private struct NotchIslandView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var uiState: NotchUIState
    fileprivate let metrics: NotchMetrics

    private var capture: AudioCaptureManager { appModel.capture }
    private var isAuto: Bool { capture.currentSegmentIndex > 0 }
    private var recording: Bool { appModel.isRecording }
    private var paused: Bool { appModel.isPaused }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var islandWidth: CGFloat {
        if uiState.pinned { return metrics.pinnedWidth }
        return uiState.isExpanded ? metrics.expandedWidth : metrics.collapsedWidth
    }
    private var islandHeight: CGFloat {
        if uiState.pinned { return metrics.pinnedHeight }
        return uiState.isExpanded ? metrics.expandedHeight : metrics.collapsedHeight
    }

    private var island: some View {
        VStack(spacing: 0) {
            topRow
                .frame(height: metrics.collapsedHeight)
            if uiState.pinned {
                setupForm
            } else if uiState.isExpanded {
                expandedBody
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .top)
        .background(BottomRoundedShape(radius: 16).fill(.black))
        .overlay(BottomRoundedShape(radius: 16).strokeBorder(.white.opacity(0.08)))
        .clipShape(BottomRoundedShape(radius: 16))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: uiState.isExpanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: uiState.pinned)
    }

    // MARK: - Pełny panel ustawień (przypięty) — sterowanie bez wracania do okna

    private var setupForm: some View {
        @Bindable var model = appModel
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Ustawienia nagrania").font(.headline).foregroundStyle(.white)
                    Spacer()
                    Button { uiState.pinned = false } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                        .help("Zwiń")
                }

                labeled("Kurs") {
                    TextField("np. Mikroekonomia", text: $model.recordCourse)
                        .textFieldStyle(.roundedBorder)
                }
                labeled(model.isAutoMode ? "Prefiks nazw (opcjonalnie)" : "Wykład") {
                    TextField(model.isAutoMode ? "np. numeracja auto" : "np. Elastyczność popytu",
                              text: $model.recordTitle)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("Tryb automatyczny (autopodział na wykłady)", isOn: $model.isAutoMode)
                    .toggleStyle(.switch).tint(.green).font(.caption).foregroundStyle(.white)

                HStack(spacing: 6) {
                    modeButton("Jedna aplikacja", .singleApp, model)
                    modeButton("Cały dźwięk", .system, model)
                }

                if model.recordMode == .singleApp {
                    labeled("Źródło") {
                        HStack(spacing: 6) {
                            Picker("", selection: $model.recordAppPID) {
                                Text("— wybierz —").tag(pid_t?.none)
                                ForEach(capture.availableApps) { app in
                                    Text(app.name).tag(pid_t?.some(app.processID))
                                }
                            }
                            .labelsHidden()
                            .onChange(of: model.recordAppPID) { _, v in
                                if v != nil { model.recordWindowID = nil; model.recordWindowName = "" }
                            }
                            Button { Task { await capture.refreshAvailableApps() } } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }

                Button { appModel.setScreenshotRegionFromButton() } label: {
                    Label(appModel.hasScreenshotRegion ? "Zmień obszar zrzutu" : "Ustaw obszar zrzutu (⌥⌘R)",
                          systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.small).tint(.white)

                HStack(spacing: 8) {
                    Button("Gotowe") { uiState.pinned = false }
                        .controlSize(.regular)
                    Button {
                        uiState.pinned = false
                        Task { await appModel.startConfiguredRecording() }
                    } label: {
                        Label(model.isAutoMode ? "Rozpocznij sesję" : "Start", systemImage: "record.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.regular).tint(.red)
                    .disabled(!appModel.canStartRecording)
                }
            }
            .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 12)
        }
    }

    private func labeled<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.6))
            content()
        }
    }

    private func modeButton(_ title: String, _ mode: CaptureMode, _ model: AppModel) -> some View {
        let selected = model.recordMode == mode
        return Button { model.recordMode = mode } label: {
            HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.caption2)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(selected ? .green : Color.white.opacity(0.14))
    }

    // Górny rząd — zawsze widoczny, treść po bokach notcha.
    @ViewBuilder private var topRow: some View {
        if metrics.hasNotch {
            HStack(spacing: 0) {
                leftFlank.frame(width: metrics.flank)
                Color.clear.frame(width: metrics.notchWidth)
                rightFlank.frame(width: metrics.flank)
            }
        } else {
            HStack(spacing: 8) {
                recordingDot
                Text(NotchStatusController.timeString(capture.elapsed))
                    .font(.system(.caption, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.white)
                Spacer(minLength: 6)
                levelBar.frame(width: 48, height: 5)
            }
            .padding(.horizontal, 14)
        }
    }

    private var leftFlank: some View {
        HStack(spacing: 5) {
            recordingDot
            if recording {
                Text(NotchStatusController.timeString(capture.elapsed))
                    .font(.system(.caption, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.white)
                if isAuto {
                    Text("·\(capture.currentSegmentIndex)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            } else {
                Text("Gotowe").font(.caption2).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rightFlank: some View {
        HStack {
            levelBar.frame(width: 56, height: 5)
        }
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var recordingDot: some View {
        Circle()
            .fill(paused ? Color.yellow : (recording ? Color.red : Color.gray))
            .frame(width: 8, height: 8)
    }

    private var levelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(.green)
                    .frame(width: geo.size.width * CGFloat(max(0, min(capture.audioLevel, 1))))
                    .animation(.linear(duration: 0.1), value: capture.audioLevel)
            }
        }
    }

    @ViewBuilder private var expandedBody: some View {
        if recording { recordingControls } else { idleControls }
    }

    private var recordingControls: some View {
        VStack(spacing: 8) {
            if isAuto {
                Text("Wykrytych wykładów: \(capture.currentSegmentIndex)")
                    .font(.caption2).foregroundStyle(.white.opacity(0.75))
            }
            HStack(spacing: 8) {
                Button { appModel.stopFromIndicator() } label: {
                    Label(isAuto ? "Zakończ" : "Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)

                Button { appModel.togglePause() } label: {
                    Label(paused ? "Wznów" : "Pauza", systemImage: paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.gray)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            // Osobny przycisk zrzutu — alternatywa dla skrótu ⌥⌘S.
            Button { appModel.captureRegionScreenshot() } label: {
                Label("Zrób zrzut obszaru", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.regular).tint(.blue)
            .help("To samo co ⌥⌘S — dolepia zrzut do notatek")

            cheatFooter
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var idleControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").font(.caption2)
                Text("Źródło: \(appModel.recordSourceLabel)")
                    .font(.caption).lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    Task { await capture.refreshAvailableApps() }
                    uiState.pinned = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                .help("Ustaw kurs, źródło i tryb tutaj")
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    Task { await capture.refreshAvailableApps() }
                    uiState.pinned = true
                } label: {
                    Label("Ustaw…", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                }
                .tint(.gray)

                Button { Task { await appModel.startConfiguredRecording() } } label: {
                    Label("Start", systemImage: "record.circle.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)
                .disabled(!appModel.canStartRecording)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            cheatFooter
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Mini-ściągawka skrótów + „?" do pełnej ściągawki.
    private var cheatFooter: some View {
        HStack(spacing: 6) {
            Text("⌥⌘S zrzut · ⌥⌘R obszar")
                .font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            Spacer(minLength: 4)
            Button { appModel.requestShortcuts() } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            .help("Pełna ściągawka skrótów")
        }
    }
}

/// Panel notcha, który MOŻE stać się oknem kluczowym (borderless domyślnie nie może),
/// dzięki czemu pola tekstowe w trybie ustawień przyjmują wpisywanie.
private final class KeyableNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Prostokąt z zaokrąglonymi tylko dolnymi rogami (góra równa z krawędzią ekranu).
private struct BottomRoundedShape: InsettableShape {
    var radius: CGFloat
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = min(self.radius, r.height)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY),
                          control: CGPoint(x: r.maxX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        path.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius),
                          control: CGPoint(x: r.minX, y: r.maxY))
        path.closeSubpath()
        return path
    }
}
