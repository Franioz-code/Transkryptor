import SwiftUI

/// Graficzny wybór okna do nagrywania (tryb A): siatka miniatur, wybór kliknięciem.
struct WindowPickerView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    var onSelect: (CaptureWindow) -> Void

    private var capture: AudioCaptureManager { appModel.capture }

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { await capture.refreshWindows() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Wybierz okno do nagrywania")
                .font(.title2.bold())
            Text("Nagrywany będzie dźwięk aplikacji, do której należy wybrane okno. Mikrofon nie jest nagrywany.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if capture.isLoadingWindows {
            VStack(spacing: 10) {
                ProgressView()
                Text("Wczytuję podglądy okien…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if capture.availableWindows.isEmpty {
            ContentUnavailableView(
                "Brak okien",
                systemImage: "macwindow",
                description: Text("Nie znaleziono okien. Upewnij się, że jest przyznana zgoda na nagrywanie ekranu, i odśwież.")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(capture.availableWindows) { window in
                        WindowCell(window: window) {
                            onSelect(window)
                            dismiss()
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await capture.refreshWindows() }
            } label: {
                Label("Odśwież", systemImage: "arrow.clockwise")
            }
            Spacer()
            Button("Anuluj", role: .cancel) { dismiss() }
        }
        .padding(16)
    }
}

private struct WindowCell: View {
    let window: CaptureWindow
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    if let thumb = window.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "macwindow")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(hovering ? Color.accentColor : Color.clear, lineWidth: 2)
                )

                Text(window.appName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(window.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
