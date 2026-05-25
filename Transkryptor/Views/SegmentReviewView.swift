import SwiftUI

/// Korekta wykrytych segmentów przed przetworzeniem: połącz / podziel / zmień nazwę / usuń.
/// Wymagana siatka bezpieczeństwa — segmentacja po ciszy to heurystyka.
struct SegmentReviewView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var splitTarget: ReviewSegment?
    @State private var splitOffset: Double = 0

    var body: some View {
        @Bindable var model = appModel

        VStack(spacing: 0) {
            header
            Divider()

            if model.pendingSegments.isEmpty {
                ContentUnavailableView("Brak segmentów", systemImage: "scissors",
                                       description: Text("Wszystkie segmenty zostały usunięte."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(model.pendingSegments.enumerated()), id: \.element.id) { index, segment in
                            segmentCard(index: index, segment: segment, titleBinding: $model.pendingSegments[index].title)
                        }
                    }
                    .padding(16)
                }
            }

            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
        .sheet(item: $splitTarget) { segment in
            splitSheet(for: segment)
        }
    }

    // MARK: - Nagłówek / stopka

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sprawdź podział na wykłady")
                .font(.title2.bold())
            Text("Podział oparty jest na przerwach ciszy — popraw go ręcznie. Dopiero po akceptacji uruchomi się pełna transkrypcja i notatki.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Anuluj", role: .cancel) {
                appModel.cancelSegmentReview()
                dismiss()
            }
            Spacer()
            Text("\(appModel.pendingSegments.count) wykład(y)")
                .foregroundStyle(.secondary)
            Button {
                appModel.processSegmentsInBackground()
                dismiss()
            } label: {
                Label("Przetwórz", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(appModel.pendingSegments.isEmpty)
        }
        .padding(16)
    }

    // MARK: - Karta segmentu

    private func segmentCard(index: Int, segment: ReviewSegment, titleBinding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(index + 1).")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                TextField("Nazwa wykładu", text: titleBinding)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 14) {
                Label(timeString(segment.start), systemImage: "clock")
                Label(durationString(segment.duration), systemImage: "hourglass")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            previewLine(segment)

            HStack(spacing: 10) {
                Button {
                    splitOffset = segment.duration / 2
                    splitTarget = segment
                } label: { Label("Podziel", systemImage: "scissors") }
                    .disabled(segment.duration < 2)

                Button {
                    appModel.mergeSegmentForward(segment.id)
                } label: { Label("Połącz z następnym", systemImage: "arrow.triangle.merge") }
                    .disabled(index >= appModel.pendingSegments.count - 1)

                Spacer()

                Button(role: .destructive) {
                    appModel.deleteSegment(segment.id)
                } label: { Label("Usuń", systemImage: "trash") }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func previewLine(_ segment: ReviewSegment) -> some View {
        if segment.previewLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Podgląd…").font(.callout).foregroundStyle(.secondary)
            }
        } else if !segment.preview.isEmpty {
            Text(segment.preview)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    // MARK: - Sheet podziału

    private func splitSheet(for segment: ReviewSegment) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Podziel „\(segment.title)”")
                .font(.headline)
            Text("Punkt podziału: \(durationString(splitOffset)) od początku segmentu")
                .font(.callout).foregroundStyle(.secondary)
            Slider(value: $splitOffset, in: 1...max(segment.duration - 1, 1))
            HStack {
                Button("Anuluj", role: .cancel) { splitTarget = nil }
                Spacer()
                Button("Podziel") {
                    appModel.splitSegment(segment.id, atAbsoluteTime: segment.start + splitOffset)
                    splitTarget = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Formatowanie czasu

    private func timeString(_ t: Double) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func durationString(_ t: Double) -> String {
        let total = Int(t.rounded())
        if total >= 60 { return "\(total / 60) min \(total % 60) s" }
        return "\(total) s"
    }
}
