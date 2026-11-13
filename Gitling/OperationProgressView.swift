import SwiftUI

struct OperationProgressCard: View {
    @Environment(\.locale) private var locale
    let state: OperationProgressState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.title).font(.headline)
            if let repository = state.repository {
                Text(repository).font(.subheadline).lineLimit(2)
            }
            Text(state.progress.phase.title(locale: locale)).font(.subheadline)
                .accessibilityIdentifier("operation.progress.phase")
            if let path = state.progress.submodule {
                Text(path).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
            }
            if let value = state.progress.fraction {
                ProgressView(value: value).progressViewStyle(.linear)
                Text(String(format: String(localized: "Current phase: %lld%%", locale: locale), Int(value * 100)))
                    .font(.caption.monospacedDigit())
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if let counts = state.progress.countText(locale: locale) {
                Text(counts).font(.caption.monospacedDigit())
            }
            if state.progress.bytes > 0 {
                Text(String(format: String(localized: "Transferred: %@", locale: locale),
                            ByteCountFormatter.string(fromByteCount: Int64(state.progress.bytes), countStyle: .file)))
                    .font(.caption.monospacedDigit())
            }
            TimelineView(.periodic(from: state.startedAt, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(state.startedAt)))
                Text(String(format: String(localized: "Elapsed: %@", locale: locale), String(format: "%02d:%02d", seconds / 60, seconds % 60)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("operation.progress")
    }
}

struct OperationProgressOverlay: View {
    let state: OperationProgressState
    @State private var contentHeight: CGFloat?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.12).ignoresSafeArea()
                ScrollView {
                    OperationProgressCard(state: state)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if height > 0 { contentHeight = height }
                        }
                }
                .frame(maxWidth: 440)
                .frame(height: min(contentHeight ?? 320, max(1, geometry.size.height * 0.85)))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding(12)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
