import SwiftUI
import AppKit

/// Lekki, natywny renderer Markdown dla notatek (nagłówki, listy, kod, akapity, obrazy).
/// Inline (pogrubienia, kursywa, kod) renderowany przez AttributedString.
struct MarkdownView: View {
    let markdown: String
    /// Katalog bazowy do rozwiązywania względnych ścieżek obrazów (`![…](baza.assets/x.png)`).
    var baseURL: URL? = nil
    /// Gdy podane, przy obrazach pojawiają się przyciski zmiany rozmiaru (path, procent szerokości).
    var onResizeImage: ((String, Int) -> Void)? = nil

    @State private var containerWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, w in containerWidth = w }
            }
        )
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)
        case let .paragraph(text):
            Text(inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case let .bullet(text):
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case let .numbered(number, text):
            HStack(alignment: .top, spacing: 6) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case let .code(code, language):
            if language?.lowercased() == "mermaid" {
                MermaidView(code: code)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if let language, !language.isEmpty {
                        Text(language)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        case let .image(alt, path, widthPercent):
            if let image = loadImage(path) {
                ResizableNoteImage(image: image, alt: alt, path: path,
                                   initialPercent: widthPercent,
                                   containerWidth: containerWidth,
                                   onResize: onResizeImage)
            } else {
                Label(alt.isEmpty ? "Zrzut: \(path)" : alt, systemImage: "photo")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case let .table(headers, rows):
            tableView(headers: headers, rows: rows)
        case .divider:
            Divider()
        }
    }

    @ViewBuilder
    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let colCount = max(headers.count, rows.map(\.count).max() ?? 0)
        if colCount > 0 {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<colCount, id: \.self) { c in
                        Text(inline(headers[safe: c] ?? ""))
                            .font(.callout.bold())
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(0..<colCount, id: \.self) { c in
                            Text(inline(rows[r][safe: c] ?? ""))
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if r < rows.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
    }

    private func loadImage(_ path: String) -> NSImage? {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else if let baseURL {
            url = baseURL.appendingPathComponent(path)
        } else {
            return nil
        }
        // Wczytanie przez Data (zamiast NSImage(contentsOf:)) omija cache — po przycięciu
        // pliku podgląd notatek pokaże nową wersję.
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .title.bold()
        case 2:  return .title2.bold()
        case 3:  return .title3.bold()
        default: return .headline
        }
    }

    private func inline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }

    // MARK: - Parser

    enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(number: Int, text: String)
        case code(String, language: String?)
        case image(alt: String, path: String, widthPercent: Int?)
        case table(headers: [String], rows: [[String]])
        case divider
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var inCode = false
        var codeLines: [String] = []
        var codeLanguage: String?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }

        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n"), language: codeLanguage))
                    codeLines.removeAll()
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                    let lang = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                    codeLanguage = lang.isEmpty ? nil : String(lang)
                }
                i += 1; continue
            }
            if inCode {
                codeLines.append(line)
                i += 1; continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1; continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
                i += 1; continue
            }
            // Tabela: wiersz z „|" + następny wiersz to separator (|---|---|).
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let headers = tableCells(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let rowTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    guard rowTrimmed.contains("|"), !rowTrimmed.isEmpty else { break }
                    rows.append(tableCells(rowTrimmed))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }
            // Obraz: ![alt](ścieżka) lub ![alt](ścieżka "NN") gdzie NN = procent szerokości
            if trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
               let sep = trimmed.range(of: "](") {
                flushParagraph()
                let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<sep.lowerBound])
                let inside = String(trimmed[sep.upperBound..<trimmed.index(before: trimmed.endIndex)])
                var path = inside
                var widthPercent: Int?
                if inside.hasSuffix("\""), let q = inside.range(of: " \"", options: .backwards) {
                    let titlePart = inside[q.upperBound..<inside.index(before: inside.endIndex)]
                    if let n = Int(titlePart) {
                        widthPercent = n
                        path = String(inside[inside.startIndex..<q.lowerBound])
                    }
                }
                blocks.append(.image(alt: alt, path: path, widthPercent: widthPercent))
                i += 1; continue
            }
            if let heading = headingLevel(trimmed) {
                flushParagraph()
                let text = String(trimmed.drop(while: { $0 == "#" }))
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: heading, text: text))
                i += 1; continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
                i += 1; continue
            }
            if let (number, rest) = numberedItem(trimmed) {
                flushParagraph()
                blocks.append(.numbered(number: number, text: rest))
                i += 1; continue
            }
            paragraph.append(trimmed)
            i += 1
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n"), language: codeLanguage))
        }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        var count = 0
        for char in line {
            if char == "#" { count += 1 } else { break }
        }
        guard count >= 1, count <= 6 else { return nil }
        let after = line.dropFirst(count).first
        return after == " " ? count : nil
    }

    private static func numberedItem(_ line: String) -> (Int, String)? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let prefix = line[line.startIndex..<dotIndex]
        guard let number = Int(prefix) else { return nil }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return (number, String(line[line.index(after: afterDot)...]))
    }

    /// Komórki wiersza tabeli (po podziale na „|", bez pustych skrajnych z zewnętrznych kresek).
    static func tableCells(_ line: String) -> [String] {
        var parts = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Czy linia to separator nagłówka tabeli, np. `|---|:--:|---|`.
    static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty
                && cell.contains("-")
                && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }
}

extension Array {
    /// Bezpieczny dostęp po indeksie (nil zamiast crashu).
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Obraz w notatkach z płynną zmianą rozmiaru przez przeciąganie uchwytu.
/// W trakcie przeciągania zmienia się tylko lokalny stan (gładko, bez zapisu),
/// a po puszczeniu szerokość jest zapisywana do notatek (jako procent szerokości kolumny).
private struct ResizableNoteImage: View {
    let image: NSImage
    let alt: String
    let path: String
    let initialPercent: Int?
    let containerWidth: CGFloat
    let onResize: ((String, Int) -> Void)?

    @State private var liveFraction: CGFloat?
    @State private var dragStartFraction: CGFloat?

    /// Udział szerokości 0…1 (nil = pełna szerokość kolumny).
    private var fraction: CGFloat? {
        if let liveFraction { return liveFraction }
        if let p = initialPercent { return CGFloat(min(max(p, 10), 100)) / 100 }
        return nil
    }

    private var displayWidth: CGFloat? {
        guard containerWidth > 0, let f = fraction else { return nil }
        return containerWidth * f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: displayWidth, alignment: .leading)
                    .frame(maxWidth: displayWidth == nil ? .infinity : nil, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

                if onResize != nil, containerWidth > 0 {
                    handle
                }
            }
            if let onResize, containerWidth > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.and.right").font(.caption2)
                    Text("\(Int(((fraction ?? 1) * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                    Text("— przeciągnij uchwyt, aby zmienić rozmiar")
                        .font(.caption2)
                    Spacer()
                    if fraction != nil {
                        Button("Pełna szerokość") {
                            liveFraction = nil
                            onResize(path, 100)
                        }
                        .buttonStyle(.link).font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var handle: some View {
        Image(systemName: "arrow.left.and.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(6)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
            .padding(6)
            .contentShape(Rectangle())
            .help("Przeciągnij, aby zmienić rozmiar")
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard containerWidth > 0 else { return }
                        let start = dragStartFraction ?? (fraction ?? 1)
                        if dragStartFraction == nil { dragStartFraction = start }
                        let delta = value.translation.width / containerWidth
                        liveFraction = min(max(start + delta, 0.15), 1.0)
                    }
                    .onEnded { _ in
                        dragStartFraction = nil
                        guard let f = liveFraction else { return }
                        onResize?(path, min(max(Int((f * 100).rounded()), 10), 100))
                    }
            )
    }
}
