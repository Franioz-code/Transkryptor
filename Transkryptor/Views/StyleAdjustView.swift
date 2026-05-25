import SwiftUI

struct StyleAdjustView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(SettingsKeys.defaultNotesStyle) private var defaultStyle = ""

    @State private var styleText = ""
    @State private var rememberAsDefault = false
    @State private var didInitialize = false

    private var canRegenerate: Bool {
        !appModel.rawTranscript.isEmpty && !appModel.phase.isBusy && appModel.hasAPIKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dostosuj styl notatek")
                .font(.headline)

            TextField(
                "np. „krócej, mniej sekcji”, „więcej przykładów”, „w punktach bez akapitów”",
                text: $styleText,
                axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)

            HStack {
                Toggle("Zapamiętaj styl jako domyślny", isOn: $rememberAsDefault)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Spacer()
                Button {
                    appModel.regenerateInBackground(
                        style: styleText,
                        rememberAsDefault: rememberAsDefault
                    )
                } label: {
                    if appModel.phase.isBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(appModel.phase == .generatingNotes ? "Generuję…" : "Pracuję…")
                        }
                    } else {
                        Label("Wygeneruj ponownie", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(!canRegenerate)
            }

            if !appModel.hasAPIKey && !appModel.rawTranscript.isEmpty {
                Label("Dodaj klucz API w Ustawieniach (⌘,), aby generować notatki. Surowa transkrypcja działa bez klucza.",
                      systemImage: "key.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .onAppear {
            if !didInitialize {
                styleText = defaultStyle
                didInitialize = true
            }
        }
    }
}
