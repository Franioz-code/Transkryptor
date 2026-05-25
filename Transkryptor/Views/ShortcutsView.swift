import SwiftUI

/// Ściągawka skrótów klawiszowych (dostępna z paska narzędzi sidebara).
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let global: [(String, String)] = [
        ("⌥⌘S", "Zrzut zapamiętanego obszaru → dolepia się do nagrania z czasem"),
        ("⌥⌘R", "Ustaw / zmień obszar zrzutu (Esc anuluje)"),
    ]
    private let inApp: [(String, String)] = [
        ("⌘R", "Start nagrywania / Rozpocznij sesję"),
        ("⌘.", "Stop / Zakończ sesję"),
        ("⌘P", "Pauza / Wznów"),
        ("⌘,", "Ustawienia"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Skróty klawiszowe")
                .font(.title2.bold())

            section("Globalne (działają też w Safari/innej apce)", global)
            section("W oknie aplikacji", inApp)

            VStack(alignment: .leading, spacing: 4) {
                Label("Notch", systemImage: "macbook")
                    .font(.headline)
                Text("Najedź na pływający wskaźnik u góry: Start/Stop, Pauza, 📷 zrzut, źródło, wybór okna.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Bezpieczeństwo", systemImage: "checkmark.shield")
                    .font(.headline)
                Text("Transkrypcja zapisuje się na bieżąco na dysk — nawet po crashu zostaje pełny tekst w historii.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Gotowe") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(rows, id: \.0) { key, desc in
                HStack(alignment: .top, spacing: 12) {
                    Text(key)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .frame(width: 56, alignment: .leading)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Text(desc).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
    }
}
