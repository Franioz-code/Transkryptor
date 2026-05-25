import Foundation
import AppKit

/// Generuje notatki przez Claude API (bezpośrednio przez URLSession, bez SDK).
struct NotesService {

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"
    private let maxTokens = 8_000
    /// Powyżej tego progu dzielimy transkrypt na części i przetwarzamy iteracyjnie.
    private let splitThreshold = 40_000
    private let chunkSize = 38_000

    /// Najtańszy, najszybszy model — używany tylko do testu połączenia.
    private let testModel = "claude-haiku-4-5-20251001"

    /// Minimalne żądanie testowe sprawdzające poprawność klucza i łączność.
    /// Nie zapisuje niczego — decyzję o zapisie podejmuje warstwa UI po sukcesie.
    func testConnection(apiKey: String) async -> APIKeyTestResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .empty }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 20

        let body: [String: Any] = [
            "model": testModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]],
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return .other(code: 0, message: "Nie udało się przygotować żądania")
        }
        request.httpBody = httpBody

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .network }
            switch http.statusCode {
            case 200:        return .success
            case 401, 403:   return .invalidKey
            default:         return .other(code: http.statusCode, message: "Niespodziewany kod odpowiedzi")
            }
        } catch {
            return .network
        }
    }

    /// Tworzy notatki z transkrypcji. `style` to wytyczne użytkownika (mogą być puste).
    /// `images` to opcjonalne zrzuty ekranu (PNG) dołączane do treści (Claude vision),
    /// `imageContext` to opis od użytkownika, czego dotyczą zrzuty.
    func generate(
        transcript: String,
        style: String,
        model: String,
        images: [Data] = [],
        imageTimes: [String] = [],
        imageFilenames: [String] = [],
        imageContext: String = ""
    ) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NotesError.emptyTranscript }

        let system = Prompts.systemPrompt(userStyle: style)

        if trimmed.count <= splitThreshold {
            let content = userContent(
                text: Prompts.userMessage(transcript: trimmed),
                images: images, imageTimes: imageTimes, imageFilenames: imageFilenames,
                imageContext: imageContext
            )
            return try await callClaude(system: system, content: content, model: model)
        }

        // Długi wykład: dziel na części i sklejaj z zachowaniem ciągłej numeracji.
        // Zrzuty dołączamy do ostatniej części (podsumowanie/wnioski).
        let chunks = splitTranscript(trimmed, maxChars: chunkSize)
        var parts: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let isLast = index == chunks.count - 1
            let message = Prompts.chunkUserMessage(
                part: index + 1, total: chunks.count, transcript: chunk
            )
            let content = userContent(
                text: message,
                images: isLast ? images : [],
                imageTimes: isLast ? imageTimes : [],
                imageFilenames: isLast ? imageFilenames : [],
                imageContext: isLast ? imageContext : ""
            )
            let part = try await callClaude(system: system, content: content, model: model)
            parts.append(part)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Buduje zawartość wiadomości: zwykły tekst albo tablicę bloków (tekst + obrazy).
    private func userContent(text: String, images: [Data], imageTimes: [String],
                             imageFilenames: [String], imageContext: String) -> Any {
        guard !images.isEmpty else { return text }
        let suffix = imageContextSuffix(imageContext, times: imageTimes, filenames: imageFilenames)
        var blocks: [[String: Any]] = [["type": "text", "text": text + suffix]]
        for data in images {
            let (mediaType, encoded) = Self.encodeForAPI(data)
            blocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": encoded,
                ],
            ])
        }
        return blocks
    }

    /// Przygotowuje zrzut do wysłania do API: zmniejsza zbyt duże obrazy i (gdy trzeba)
    /// przekodowuje na JPEG, żeby zmieścić się w limicie 5 MB Anthropic. Zapis na dysku
    /// pozostaje pełnym PNG — to dotyczy tylko kopii wysyłanej do modelu.
    static func encodeForAPI(_ data: Data) -> (mediaType: String, base64: String) {
        let maxBytes = 4_500_000          // bufor pod twardy limit 5 MiB
        let maxEdge: CGFloat = 1568        // zalecany przez Anthropic dłuższy bok

        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ("image/png", data.base64EncodedString())
        }

        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxEdge / max(w, h, 1))

        // Mały i lekki PNG — zostaw bez zmian (ostrość tekstu/diagramu).
        if scale >= 1, data.count <= maxBytes {
            return ("image/png", data.base64EncodedString())
        }

        let targetW = max(1, Int((w * scale).rounded()))
        let targetH = max(1, Int((h * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: targetW, pixelsHigh: targetH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            return ("image/png", data.base64EncodedString())
        }
        rep.size = NSSize(width: targetW, height: targetH)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.set()                                   // białe tło zamiast przezroczystości (JPEG)
        NSRect(x: 0, y: 0, width: targetW, height: targetH).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        // Spróbuj PNG po zmniejszeniu; jeśli wciąż za duży — JPEG z malejącą jakością.
        if scale < 1, let png = rep.representation(using: .png, properties: [:]), png.count <= maxBytes {
            return ("image/png", png.base64EncodedString())
        }
        for quality in [0.8, 0.6, 0.45, 0.3, 0.2] {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpeg.count <= maxBytes {
                return ("image/jpeg", jpeg.base64EncodedString())
            }
        }
        if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.15]) {
            return ("image/jpeg", jpeg.base64EncodedString())
        }
        return ("image/png", data.base64EncodedString())
    }

    private func imageContextSuffix(_ context: String, times: [String], filenames: [String]) -> String {
        var base = "\n\nDołączam zrzuty ekranu z istotnymi fragmentami wykładu (np. slajdy, diagramy, kod), zrobione w trakcie nagrania (w kolejności obrazów)."
        if !filenames.isEmpty {
            let list = filenames.enumerated().map { i, name in
                let t = i < times.count ? " (czas \(times[i]))" : ""
                return "  \(i + 1)) \(name)\(t)"
            }.joined(separator: "\n")
            base += "\nLista plików zrzutów:\n\(list)\n"
            base += "WAŻNE: Każdy zrzut WSTAW do notatek jako składnię Markdown obrazu: `![krótki opis](NAZWA_PLIKU)` — używając DOKŁADNIE podanej nazwy pliku — w miejscu odpowiadającym jego czasowi (przy temacie z tego momentu wykładu). Nie pomijaj żadnego zrzutu. Pod obrazem możesz dodać jedno zdanie opisu."
        } else if !times.isEmpty {
            let list = times.enumerated().map { "  \($0.offset + 1)) czas \($0.element)" }.joined(separator: "\n")
            base += " Czas każdego: \(list). Uwzględnij ich treść w odpowiednich miejscach."
        } else {
            base += " Uwzględnij ich treść w odpowiednich miejscach notatek."
        }
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? base : base + "\n\nKontekst do zrzutów od użytkownika: \(trimmed)"
    }

    // MARK: - Wywołanie API

    private func callClaude(system: String, content: Any, model: String) async throws -> String {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw NotesError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 300

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": content]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NotesError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = parseErrorMessage(data) ?? "HTTP \(http.statusCode)"
            throw NotesError.api(message)
        }
        return try parseText(data)
    }

    // MARK: - Parsowanie odpowiedzi

    private struct APIResponse: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
    }

    private struct APIError: Decodable {
        struct ErrorBody: Decodable { let message: String }
        let error: ErrorBody
    }

    private func parseText(_ data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        let text = decoded.content
            .compactMap { $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NotesError.invalidResponse }
        return text
    }

    private func parseErrorMessage(_ data: Data) -> String? {
        (try? JSONDecoder().decode(APIError.self, from: data))?.error.message
    }

    // MARK: - Dzielenie długich transkryptów

    private func splitTranscript(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }

        var chunks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }

        // Najpierw po akapitach, a bardzo długie akapity po zdaniach.
        for paragraph in text.components(separatedBy: "\n") {
            if paragraph.count > maxChars {
                for sentence in paragraph.components(separatedBy: ". ") {
                    if current.count + sentence.count + 2 > maxChars, !current.isEmpty { flush() }
                    current += sentence + ". "
                }
            } else {
                if current.count + paragraph.count + 1 > maxChars, !current.isEmpty { flush() }
                current += paragraph + "\n"
            }
        }
        flush()
        return chunks
    }
}

/// Wynik testu połączenia z Anthropic API. Bez treści klucza w komunikatach.
enum APIKeyTestResult: Equatable {
    case success
    case empty
    case invalidKey
    case network
    case other(code: Int, message: String)
}

enum NotesError: LocalizedError {
    case missingAPIKey
    case emptyTranscript
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Brak klucza Anthropic API. Dodaj go w Ustawieniach."
        case .emptyTranscript:
            return "Transkrypcja jest pusta — nie ma z czego utworzyć notatek."
        case .invalidResponse:
            return "Nieprawidłowa odpowiedź z Claude API."
        case let .api(message):
            return "Claude API: \(message)"
        }
    }
}
