import SwiftUI
import AppKit

/// Galeria zrzutów ekranu: w trakcie sesji pokazuje zrzuty robocze (wklejanie ⌘V / ⌥⌘S,
/// usuwanie, kontekst), a przy oglądaniu zapisanego wykładu — zrzuty z dysku.
/// Zawsze z podglądem, powiększeniem i sortowaniem wg czasu — bez szukania w Finderze.
struct AttachmentsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var preview: GalleryItem?
    @State private var liveToDelete: UUID?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    private var items: [GalleryItem] {
        _ = appModel.galleryRefresh   // odśwież po przycięciu zrzutu
        if !appModel.attachedImages.isEmpty {
            return appModel.attachedImages
                .sorted { $0.timestamp < $1.timestamp }
                .map { GalleryItem(id: $0.id.uuidString, image: $0.image,
                                   time: $0.timestamp, liveID: $0.id, fileURL: nil) }
        }
        return appModel.lectureScreenshots.compactMap { shot in
            // Wczytanie przez Data omija cache — po przycięciu pokaże nową wersję.
            guard let data = try? Data(contentsOf: shot.url),
                  let image = NSImage(data: data) else { return nil }
            return GalleryItem(id: shot.url.path, image: image,
                               time: shot.time ?? 0, liveID: nil, fileURL: shot.url)
        }
    }

    var body: some View {
        @Bindable var appModel = appModel
        let items = items

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Zrzuty ekranu").font(.headline)
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if !appModel.lectureScreenshots.isEmpty {
                    Button { appModel.revealLectureFiles() } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Pokaż zrzuty w Finderze")
                }
                PasteButton(payloadType: NSImage.self) { images in
                    for image in images { appModel.addImage(image) }
                }
                .controlSize(.small)
            }

            if items.isEmpty {
                Text("Zrzuty zrobione w trakcie wykładu (skrót ⌥⌘S albo Wklej ⌘V) pojawią się tutaj — z podglądem i powiększeniem, posortowane wg czasu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { item in thumbnail(item) }
                }
                if !appModel.attachedImages.isEmpty {
                    TextField("Czego dotyczą zrzuty? (kontekst, opcjonalnie)",
                              text: $appModel.attachmentContext, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Kliknij miniaturę, aby powiększyć.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .sheet(item: $preview) { item in
            ScreenshotViewer(items: items, current: item) { appModel.removeAttachment($0) }
        }
        .confirmationDialog("Usunąć ten zrzut?",
                            isPresented: Binding(get: { liveToDelete != nil },
                                                 set: { if !$0 { liveToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Usuń", role: .destructive) {
                if let id = liveToDelete { appModel.removeAttachment(id) }
                liveToDelete = nil
            }
            Button("Anuluj", role: .cancel) { liveToDelete = nil }
        } message: {
            Text("Zrzut zostanie trwale usunięty z dysku.")
        }
    }

    private func thumbnail(_ item: GalleryItem) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 70)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .overlay(alignment: .bottomLeading) {
                    if item.time > 0 {
                        Text(AppModel.timeLabel(item.time))
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(3)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { preview = item }
                .help("Kliknij, aby powiększyć")

            if let liveID = item.liveID {
                Button { liveToDelete = liveID } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(2)
                .help("Usuń zrzut")
            }
        }
    }
}

/// Element galerii — z pamięci (sesja, do usunięcia) lub z dysku (zapisany wykład).
struct GalleryItem: Identifiable {
    let id: String
    let image: NSImage
    let time: TimeInterval
    let liveID: UUID?
    let fileURL: URL?
}

/// Powiększony podgląd z nawigacją (←/→), znacznikiem czasu, przycinaniem i akcjami.
private struct ScreenshotViewer: View {
    let items: [GalleryItem]
    let onDelete: (UUID) -> Void
    @Environment(AppModel.self) private var appModel
    @State private var index: Int
    @State private var cropping = false
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    init(items: [GalleryItem], current: GalleryItem, onDelete: @escaping (UUID) -> Void) {
        self.items = items
        self.onDelete = onDelete
        _index = State(initialValue: items.firstIndex { $0.id == current.id } ?? 0)
    }

    private var item: GalleryItem? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                if let t = item?.time, t > 0 {
                    Label(AppModel.timeLabel(t), systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(cropping ? "Przytnij zrzut" : "Zrzut \(index + 1) z \(items.count)")
                    .font(.headline)
                Spacer()
                Color.clear.frame(width: 70, height: 1)
            }

            if let item {
                if cropping {
                    ScreenshotCropView(image: item.image) { normalized in
                        if let url = item.fileURL {
                            appModel.cropSavedScreenshot(at: url, normalized: normalized)
                        } else if let liveID = item.liveID {
                            appModel.cropAttachment(liveID, normalized: normalized)
                        }
                        cropping = false
                        dismiss()
                    } onCancel: {
                        cropping = false
                    }
                } else {
                    Image(nsImage: item.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            if !cropping {
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(index <= 0)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(index >= items.count - 1)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Button { cropping = true } label: {
                        Label("Przytnij", systemImage: "crop")
                    }
                    Spacer()
                    if let fileURL = item?.fileURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        } label: {
                            Label("Pokaż w Finderze", systemImage: "folder")
                        }
                    }
                    if item?.liveID != nil || item?.fileURL != nil {
                        Button("Usuń zrzut", role: .destructive) { confirmingDelete = true }
                    }
                    Button("Zamknij") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
        .confirmationDialog("Usunąć ten zrzut na stałe?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Usuń", role: .destructive) { performDelete() }
            Button("Anuluj", role: .cancel) { }
        } message: {
            Text("Zrzut zostanie trwale usunięty z dysku i z notatek.")
        }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        if items.indices.contains(next) { index = next }
    }

    private func performDelete() {
        guard let item else { return }
        if let url = item.fileURL {
            appModel.deleteSavedScreenshot(at: url)
        } else if let liveID = item.liveID {
            onDelete(liveID)
        }
        dismiss()
    }
}

/// Edytor kadrowania: zaznacz prostokąt do zachowania (reszta zostanie odcięta).
/// Zaznaczenie trzymamy w układzie znormalizowanym 0…1 (lewy-górny róg obrazu),
/// więc działa niezależnie od skali wyświetlania.
private struct ScreenshotCropView: View {
    let image: NSImage
    let onApply: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var startN: CGPoint?
    @State private var currentN: CGPoint?

    var body: some View {
        VStack(spacing: 10) {
            Text("Przeciągnij, aby zaznaczyć obszar do zachowania — reszta zostanie odcięta.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geo in
                let imageRect = fittedRect(in: geo.size)
                let selection = selectionViewRect(in: imageRect)
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                    Canvas { ctx, size in
                        var dim = Path(CGRect(origin: .zero, size: size))
                        if let selection { dim.addRect(selection) }
                        ctx.fill(dim, with: .color(.black.opacity(0.5)),
                                 style: FillStyle(eoFill: true))
                        if let selection {
                            ctx.stroke(Path(selection), with: .color(.white), lineWidth: 2)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if startN == nil { startN = normalize(value.startLocation, in: imageRect) }
                            currentN = normalize(value.location, in: imageRect)
                        }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Anuluj", role: .cancel) { onCancel() }
                Spacer()
                Button("Resetuj zaznaczenie") { startN = nil; currentN = nil }
                    .disabled(startN == nil)
                Button("Zachowaj zaznaczenie") {
                    if let r = selectionNormalized() { onApply(r) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasSelection)
            }
        }
    }

    private var hasSelection: Bool {
        guard let r = selectionNormalized() else { return false }
        return r.width > 0.01 && r.height > 0.01
    }

    /// Zaznaczenie w układzie znormalizowanym 0…1.
    private func selectionNormalized() -> CGRect? {
        guard let s = startN, let c = currentN else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    /// Zaznaczenie przeliczone na współrzędne widoku (do rysowania).
    private func selectionViewRect(in imageRect: CGRect) -> CGRect? {
        guard let n = selectionNormalized() else { return nil }
        return CGRect(x: imageRect.minX + n.minX * imageRect.width,
                      y: imageRect.minY + n.minY * imageRect.height,
                      width: n.width * imageRect.width,
                      height: n.height * imageRect.height)
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let iw = image.size.width, ih = image.size.height
        guard iw > 0, ih > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / iw, size.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Punkt widoku → znormalizowany (z przycięciem do obszaru obrazu).
    private func normalize(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let x = min(max((p.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((p.y - rect.minY) / rect.height, 0), 1)
        return CGPoint(x: x, y: y)
    }
}
