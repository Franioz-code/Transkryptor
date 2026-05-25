import AppKit

/// Zrzuty zaznaczonego obszaru ekranu. Obszar zaznacza się raz i jest zapamiętywany,
/// więc kolejne zrzuty (na skrót) łapią ten sam prostokąt bez celowania.
@MainActor
final class ScreenshotService {
    private let regionKey = "screenshotRegion"   // [x,y,w,h] w układzie CGWindowListCreateImage (origin lewy-górny)
    private var selector: RegionSelectorWindow?

    var savedRegion: CGRect? {
        let d = UserDefaults.standard
        guard let arr = d.array(forKey: regionKey) as? [Double], arr.count == 4 else { return nil }
        return CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
    }

    func saveRegion(_ r: CGRect) {
        UserDefaults.standard.set([r.origin.x, r.origin.y, r.width, r.height], forKey: regionKey)
    }

    func clearRegion() { UserDefaults.standard.removeObject(forKey: regionKey) }

    /// Łapie obszar ekranu (współrzędne CGWindowListCreateImage: origin lewy-górny).
    func capture(region: CGRect) -> NSImage? {
        guard region.width > 1, region.height > 1 else { return nil }
        guard let cg = CGWindowListCreateImage(
            region, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution, .boundsIgnoreFraming]
        ) else { return nil }
        return NSImage(cgImage: cg, size: region.size)
    }

    /// Pokazuje nakładkę do zaznaczenia obszaru; zwraca prostokąt w układzie CGWindowListCreateImage.
    func selectRegion(completion: @escaping (CGRect?) -> Void) {
        // Blokada wielokrotnego otwarcia — bez tego nakładki stackowały się i nie dało się ich zamknąć.
        guard selector == nil else { return }
        let selector = RegionSelectorWindow { [weak self] rect in
            self?.selector = nil
            completion(rect)
        }
        self.selector = selector
        selector.show()
    }
}

/// Pełnoekranowa nakładka z przeciąganiem prostokąta zaznaczenia.
@MainActor
private final class RegionSelectorWindow {
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var finished = false
    private let completion: (CGRect?) -> Void

    init(completion: @escaping (CGRect?) -> Void) { self.completion = completion }

    func show() {
        // Nakładka nad EKRANEM, na którym jest kursor (tam, gdzie patrzysz — np. pełnoekranowe Safari).
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { completion(nil); return }

        // Nieaktywujący panel (jak notch) — pojawia się nad bieżącym Space BEZ przełączania.
        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false

        let view = RegionSelectorView(frame: NSRect(origin: .zero, size: screen.frame.size)) { [weak self] rectInView in
            self?.finish(rectInView, screen: screen)
        }
        panel.contentView = view
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(view)
        self.window = panel

        // Esc = anuluj (lokalny monitor — gdy aplikacja jest aktywna; klik bez przeciągania anuluje zawsze).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.finish(nil, screen: screen)
                return nil
            }
            return event
        }
    }

    private func finish(_ rectInView: CGRect?, screen: NSScreen) {
        guard !finished else { return }
        finished = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        window?.orderOut(nil)
        window = nil

        let result: CGRect?
        if let rectInView, rectInView.width > 4, rectInView.height > 4 {
            // rectInView: współrzędne widoku (origin lewy-DOLNY). Przeliczamy na układ
            // CGWindowListCreateImage (origin lewy-GÓRNY ekranu głównego), odbijając Y.
            let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? screen).frame.height
            let nsX = screen.frame.origin.x + rectInView.origin.x
            let nsY = screen.frame.origin.y + rectInView.origin.y
            result = CGRect(x: nsX, y: primaryHeight - (nsY + rectInView.height),
                            width: rectInView.width, height: rectInView.height)
        } else {
            result = nil
        }
        // Po orderOut daj klatkę, żeby nakładka zniknęła z ekranu zanim zrobimy zrzut.
        DispatchQueue.main.async { [completion] in completion(result) }
    }
}

private final class RegionSelectorView: NSView {
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private let onFinish: (CGRect?) -> Void

    init(frame: NSRect, onFinish: @escaping (CGRect?) -> Void) {
        self.onFinish = onFinish
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        onFinish(selectionRect)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish(nil) }   // ESC = anuluj
    }

    private var selectionRect: CGRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        guard let sel = selectionRect else {
            drawHint()
            return
        }
        // „Wytnij" zaznaczenie (pokaż pulpit pod spodem) + obrys.
        NSColor.clear.set()
        sel.fill(using: .clear)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: sel)
        path.lineWidth = 2
        path.stroke()
    }

    private func drawHint() {
        let text = "Przeciągnij prostokąt na obszarze filmu.  Klik bez przeciągania lub Esc = anuluj." as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.5),
                  withAttributes: attrs)
    }
}
