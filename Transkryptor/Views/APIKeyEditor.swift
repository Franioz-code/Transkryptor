import SwiftUI

/// Pole klucza Anthropic API z testem połączenia. Zapisuje do Keychain WYŁĄCZNIE klucz,
/// który przeszedł test (HTTP 200). Używane w Ustawieniach i w Onboardingu.
struct APIKeyEditor: View {
    @Environment(AppModel.self) private var appModel
    var onSaved: (() -> Void)? = nil

    @State private var keyText = ""
    @State private var isRevealed = false
    @State private var isChecking = false
    @State private var status: Status = .neutral("")

    private enum Status {
        case neutral(String)
        case success(String)
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Group {
                    if isRevealed {
                        TextField("sk-ant-...", text: $keyText)
                    } else {
                        SecureField("sk-ant-...", text: $keyText)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(isChecking)

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .help(isRevealed ? "Ukryj klucz" : "Pokaż klucz")
            }

            HStack(spacing: 12) {
                Button {
                    Task { await checkAndSave() }
                } label: {
                    HStack(spacing: 6) {
                        if isChecking { ProgressView().controlSize(.small) }
                        Text(isChecking ? "Sprawdzam…" : "Sprawdź API i zapisz")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isChecking || keyText.trimmingCharacters(in: .whitespaces).isEmpty)

                if KeychainService.hasAPIKey {
                    Button("Usuń klucz", role: .destructive) {
                        KeychainService.deleteAPIKey()
                        keyText = ""
                        status = .neutral("Klucz usunięty z Keychain.")
                    }
                    .disabled(isChecking)
                }
                Spacer()
            }

            statusView
        }
        .onAppear {
            if keyText.isEmpty { keyText = KeychainService.loadAPIKey() ?? "" }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case let .neutral(message):
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case let .error(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    private func checkAndSave() async {
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            status = .error("Wpisz klucz API.")
            return
        }
        isChecking = true
        status = .neutral("Sprawdzam…")

        let result = await appModel.notes.testConnection(apiKey: key)
        switch result {
        case .success:
            KeychainService.saveAPIKey(key)
            status = .success("Połączenie OK, klucz zapisany")
            onSaved?()
        case .empty:
            status = .error("Wpisz klucz API.")
        case .invalidKey:
            status = .error("Nieprawidłowy klucz API")
        case .network:
            status = .error("Brak połączenia z API")
        case let .other(code, message):
            status = .error("Błąd \(code): \(message)")
        }
        isChecking = false
    }
}
