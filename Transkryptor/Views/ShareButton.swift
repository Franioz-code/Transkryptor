import SwiftUI
import AppKit

/// Przycisk „Udostępnij" otwierający systemowy arkusz udostępniania (m.in. Apple Notes,
/// Mail, Wiadomości). Udostępnia notatki jako tekst sformatowany z osadzonymi obrazami.
struct ShareNotesButton: View {
    /// Dostawca treści wywoływany w momencie kliknięcia (świeży snapshot notatek).
    let content: () -> NSAttributedString?

    var body: some View {
        SharePicker(content: content)
            .frame(width: 30, height: 24)
            .help("Udostępnij notatki (Apple Notes, Mail…)")
    }
}

private struct SharePicker: NSViewRepresentable {
    let content: () -> NSAttributedString?

    func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: "square.and.arrow.up",
                            accessibilityDescription: "Udostępnij")
        let button = NSButton(image: image ?? NSImage(),
                              target: context.coordinator,
                              action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.isBordered = true
        context.coordinator.content = content
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.content = content
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var content: (() -> NSAttributedString?)?

        @objc func share(_ sender: NSButton) {
            guard let attr = content?(), attr.length > 0 else { NSSound.beep(); return }
            let picker = NSSharingServicePicker(items: [attr])
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
