import AppKit
import Foundation

/// Konwertuje Markdown notatek na `NSAttributedString` (RTFD) z osadzonymi obrazami —
/// gotowy do skopiowania / udostępnienia do Apple Notes (zachowuje formatowanie i zrzuty).
enum NotesRichText {

    static func attributed(markdown: String, baseURL: URL?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let blocks = MarkdownView.parse(markdown)
        for (i, block) in blocks.enumerated() {
            out.append(render(block, baseURL: baseURL, isFirst: i == 0))
        }
        return out
    }

    // MARK: - Render bloków

    private static func render(_ block: MarkdownView.Block, baseURL: URL?, isFirst: Bool) -> NSAttributedString {
        switch block {
        case let .heading(level, text):
            let s = NSMutableAttributedString()
            if !isFirst { s.append(plain("\n")) }
            s.append(inline(text, base: headingFont(level)))
            s.append(plain("\n"))
            return paragraphStyled(s, spacingAfter: 4)

        case let .paragraph(text):
            let s = NSMutableAttributedString(attributedString: inline(text, base: bodyFont))
            s.append(plain("\n"))
            return paragraphStyled(s, spacingAfter: 6)

        case let .bullet(text):
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: "•  ", attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor]))
            s.append(inline(text, base: bodyFont))
            s.append(plain("\n"))
            return paragraphStyled(s, spacingAfter: 2)

        case let .numbered(number, text):
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: "\(number).  ", attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor]))
            s.append(inline(text, base: bodyFont))
            s.append(plain("\n"))
            return paragraphStyled(s, spacingAfter: 2)

        case let .code(code, _):
            let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let s = NSMutableAttributedString(string: code + "\n",
                                              attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
            return paragraphStyled(s, spacingAfter: 6)

        case let .image(alt, path, widthPercent):
            return imageBlock(alt: alt, path: path, widthPercent: widthPercent, baseURL: baseURL)

        case let .table(headers, rows):
            return tableBlock(headers: headers, rows: rows)

        case .divider:
            return NSAttributedString(string: "————————\n",
                                      attributes: [.font: bodyFont, .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }

    private static func imageBlock(alt: String, path: String, widthPercent: Int?, baseURL: URL?) -> NSAttributedString {
        guard let data = imageData(path, baseURL: baseURL), let image = NSImage(data: data) else {
            return NSAttributedString(string: (alt.isEmpty ? "[zrzut ekranu]" : alt) + "\n",
                                      attributes: [.font: captionFont, .foregroundColor: NSColor.secondaryLabelColor])
        }
        let attachment = NSTextAttachment()
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = path.hasPrefix("data:") ? "obraz.jpg" : (resolve(path, baseURL: baseURL)?.lastPathComponent ?? "obraz")
        attachment.fileWrapper = wrapper

        let cap: CGFloat = 520
        let size = image.size
        let target: CGFloat
        if let percent = widthPercent {
            target = cap * CGFloat(min(max(percent, 10), 100)) / 100   // jawny rozmiar z notatek
        } else {
            target = min(size.width, cap)
        }
        let scale = size.width > 0 ? target / size.width : 1
        attachment.bounds = CGRect(x: 0, y: 0,
                                   width: max(1, size.width * scale),
                                   height: max(1, size.height * scale))

        let s = NSMutableAttributedString(attachment: attachment)
        s.append(plain("\n"))
        if !alt.isEmpty {
            s.append(inline(alt, base: captionFont))
            s.append(plain("\n"))
        }
        return paragraphStyled(s, spacingAfter: 8)
    }

    /// Buduje natywną tabelę (NSTextTable) — Apple Notes renderuje ją jako tabelę po wklejeniu.
    private static func tableBlock(headers: [String], rows: [[String]]) -> NSAttributedString {
        let colCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard colCount > 0 else { return plain("\n") }

        let table = NSTextTable()
        table.numberOfColumns = colCount
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true

        let result = NSMutableAttributedString()
        let allRows = [headers] + rows
        for (rowIndex, row) in allRows.enumerated() {
            for col in 0..<colCount {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                             startingColumn: col, columnSpan: 1)
                block.setBorderColor(.gray)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(5, type: .absoluteValueType, for: .padding)
                if rowIndex == 0 {
                    block.backgroundColor = NSColor.controlBackgroundColor
                }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]

                let isHeader = rowIndex == 0
                let cell = NSMutableAttributedString(
                    attributedString: inline(row[safe: col] ?? "",
                                             base: isHeader ? NSFont.boldSystemFont(ofSize: 13) : bodyFont)
                )
                cell.append(NSAttributedString(string: "\n"))
                cell.addAttribute(.paragraphStyle, value: style,
                                  range: NSRange(location: 0, length: cell.length))
                result.append(cell)
            }
        }
        return result
    }

    // MARK: - Inline (pogrubienia, kursywa, kod)

    private static func inline(_ string: String, base: NSFont) -> NSAttributedString {
        let parsed: NSAttributedString
        if let a = try? NSAttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace),
            baseURL: nil
        ) {
            parsed = a
        } else {
            parsed = NSAttributedString(string: string)
        }

        let m = NSMutableAttributedString(attributedString: parsed)
        let full = NSRange(location: 0, length: m.length)
        let mono = NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)

        m.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            var font = base
            var intent: InlinePresentationIntent?
            if let i = value as? InlinePresentationIntent {
                intent = i
            } else if let raw = value as? UInt {
                intent = InlinePresentationIntent(rawValue: raw)
            } else if let rawInt = value as? Int {
                intent = InlinePresentationIntent(rawValue: UInt(rawInt))
            }
            if let intent {
                if intent.contains(.code) {
                    font = mono
                } else {
                    if intent.contains(.stronglyEmphasized) {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    }
                    if intent.contains(.emphasized) {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    }
                }
            }
            m.addAttribute(.font, value: font, range: range)
            m.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
        return m
    }

    // MARK: - Pomocnicze

    private static let bodyFont = NSFont.systemFont(ofSize: 13)
    private static let captionFont = NSFont.systemFont(ofSize: 11)

    private static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1:  return .boldSystemFont(ofSize: 22)
        case 2:  return .boldSystemFont(ofSize: 18)
        case 3:  return .boldSystemFont(ofSize: 15)
        default: return .boldSystemFont(ofSize: 13)
        }
    }

    private static func plain(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor])
    }

    private static func paragraphStyled(_ s: NSMutableAttributedString, spacingAfter: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacingAfter
        style.lineSpacing = 1
        s.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: s.length))
        return s
    }

    private static func resolve(_ path: String, baseURL: URL?) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if let baseURL { return baseURL.appendingPathComponent(path) }
        return nil
    }

    /// Dane obrazu z pliku lub wtopionego data:base64.
    private static func imageData(_ path: String, baseURL: URL?) -> Data? {
        if path.hasPrefix("data:"), let comma = path.firstIndex(of: ",") {
            return Data(base64Encoded: String(path[path.index(after: comma)...]))
        }
        guard let url = resolve(path, baseURL: baseURL) else { return nil }
        return try? Data(contentsOf: url)
    }
}
