import SwiftUI

struct PreviewArchiveList: View {
    let index: PreviewArchiveIndex
    var body: some View {
        List {
            Section {
                Text("ZIP directory only. No files are extracted or opened.")
                Text(String(format: String(localized: "%lld of %lld archive entries"), index.entries.count, index.total))
                if index.truncated { Text("Archive listing truncated at the entry limit.") }
            }
            ForEach(index.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.path).font(.body.monospaced()).textSelection(.enabled)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file)).font(.caption)
                    if entry.encrypted { Label("Encrypted entry", systemImage: "lock") }
                    if entry.unsafePath { Label("Unsafe archive path — not followed", systemImage: "exclamationmark.triangle") }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("file.preview.archive")
    }
}

struct PreviewHexView: View {
    let page: PreviewHexPage
    let loading: Bool
    let move: (Int) -> Void
    var body: some View {
        VStack(spacing: 8) {
            AdaptiveActionGroup {
                Button("Previous Page") { move(-1) }.disabled(loading || !page.hasPrevious)
                Button("Next Page") { move(1) }.disabled(loading || !page.hasNext)
            }
            Text(String(format: String(localized: "Bytes %lld–%lld of %lld"), page.offset, page.offset + page.data.count, page.total))
                .font(.caption.monospacedDigit())
            if loading { ProgressView() }
            SourceTextView(text: page.text, spans: [])
        }
        .padding(.top, 8)
        .accessibilityIdentifier("file.preview.hex")
    }
}

struct ComparisonVersionPreviewPage: View {
    let repo: URL
    let comparison: CommitComparison
    let file: ComparisonFile
    @State private var target = true
    init(repo: URL, comparison: CommitComparison, file: ComparisonFile) {
        self.repo = repo; self.comparison = comparison; self.file = file
        _target = State(initialValue: file.newPath != nil)
    }
    var body: some View {
        GeometryReader { geometry in
            DiffPanelLayout {
                ComparisonHeaderViewport(maximumHeight: max(96, min(240, geometry.size.height * 0.35))) {
                    header
                }
            } content: {
                if let path = target ? file.newPath : file.oldPath {
                    PreviewContentsPage(repo: repo, source: .blob(oid: target ? comparison.target.oid : comparison.base.oid, path: path))
                } else {
                    ContentUnavailableView("Files", systemImage: "doc", description: Text("This commit does not contain this file."))
                }
            }
        }
        .navigationTitle("Preview versions")
        .navigationBarTitleDisplayMode(.inline)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Version", selection: $target) {
                Text("Base commit").tag(false)
                Text("Target commit").tag(true)
            }
            .pickerStyle(.menu)
            Text(target ? comparison.target.oid : comparison.base.oid).font(.caption.monospaced()).textSelection(.enabled)
            Text((target ? file.newPath : file.oldPath) ?? String(localized: "This commit does not contain this file."))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
    }
}
