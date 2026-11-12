import SwiftUI
import UIKit

enum FileInspectSection: Hashable {
    case contents, history, blame
}

struct FileInspectPicker: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Binding var section: FileInspectSection

    var body: some View {
        Group {
            if textSize >= .xxxLarge { picker.pickerStyle(.menu) }
            else {
                ViewThatFits(in: .horizontal) {
                    picker.pickerStyle(.segmented).frame(minWidth: 300)
                    picker.pickerStyle(.menu)
                }
            }
        }
        .accessibilityIdentifier("file.inspect.section")
    }

    private var picker: some View {
        Picker("File", selection: $section) {
            Text("Contents").tag(FileInspectSection.contents)
            Text("File History").tag(FileInspectSection.history)
            Text("Blame").tag(FileInspectSection.blame)
        }
    }
}

struct FilePreview: View {
    @EnvironmentObject private var store: RepoStore
    let repo: URL
    let relative: String
    let name: String
    @State private var section = FileInspectSection.contents

    var body: some View {
        DiffPanelLayout {
            FileInspectPicker(section: $section).padding(.horizontal)
        } content: {
            switch section {
            case .contents:
                FileContentsPage(repo: repo, relative: relative)
            case .history:
                FileHistoryList(repo: repo, path: relative, revision: store.revision)
            case .blame:
                FileBlameList(repo: repo, path: relative, revision: store.revision)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }
}

private struct FileContentsPage: View {
    let repo: URL
    let relative: String
    @State private var text: String?
    @State private var spans: [SyntaxSpan] = []
    @State private var error: String?

    var body: some View {
        Group {
            if let text {
                SourceTextView(text: text, spans: spans)
            } else if let error {
                ContentUnavailableView("Files", systemImage: "doc", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            do {
                let repo = repo
                let relative = relative
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try GitClient.readText(at: repo, relative: relative)
                }.value
                let highlighted = await Task.detached(priority: .userInitiated) {
                    SyntaxHighlighter.spans(in: loaded, path: relative)
                }.value
                guard !Task.isCancelled else { return }
                text = loaded
                spans = highlighted
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

private struct FileHistoryList: View {
    let repo: URL
    let path: String
    let revision: Int
    @StateObject private var model = RepositorySearchModel<FileHistoryEntry>()

    var body: some View {
        List {
            Section {
                Text("History follows HEAD through first parents and similar-file renames.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red)
            } else if model.isLoading && model.items.isEmpty {
                ProgressView()
            } else if model.items.isEmpty {
                Text("No commits for this file on the current branch.")
                    .foregroundStyle(.secondary)
            } else {
                RepositorySearchStatus(loading: model.isLoading, count: model.items.count, scanned: model.scanned, hasMore: model.hasMore)
                ForEach(model.items) { entry in
                    NavigationLink {
                        FileRevisionPage(repo: repo, entry: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.commit.summary)
                            Text(FileInspectionLabels.change(entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.commit.author + " · " + entry.commit.date.formatted())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(entry.commit.id.prefix(12)))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if model.hasMore {
                    Button("Load More History") { Task { await model.loadMore() } }
                        .disabled(model.isLoading)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .task(id: revision) {
            let repo = repo
            let path = path
            await model.search(debounce: false) { token in
                try GitClient.fileHistory(at: repo, path: path, cancellation: token)
            }
        }
        .onDisappear { model.cancel() }
    }
}

private struct FileRevisionPage: View {
    let repo: URL
    let entry: FileHistoryEntry
    @State private var state: FileBlobState?
    @State private var spans: [SyntaxSpan] = []
    @State private var error: String?

    var body: some View {
        DiffPanelLayout {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.commit.summary).font(.headline)
                Text(FileInspectionLabels.change(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(entry.commit.id.prefix(12)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        } content: {
            if let error {
                ContentUnavailableView("Files", systemImage: "doc", description: Text(error))
            } else if let state {
                revisionBody(state)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle((entry.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: entry.id + "\n" + entry.path) {
            do {
                let repo = repo
                let commit = entry.commit.id
                let path = entry.path
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try GitClient.fileRevision(at: repo, commit: commit, path: path)
                }.value
                let highlighted: [SyntaxSpan]
                if case .text(let text) = loaded {
                    highlighted = await Task.detached(priority: .userInitiated) {
                        SyntaxHighlighter.spans(in: text, path: path)
                    }.value
                } else {
                    highlighted = []
                }
                guard !Task.isCancelled else { return }
                state = loaded
                spans = highlighted
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func revisionBody(_ state: FileBlobState) -> some View {
        switch state {
        case .text(let text):
            SourceTextView(text: text, spans: spans)
        case .missing:
            Text("This commit does not contain this file.").padding()
        case .binary:
            Text("This version is binary.").padding()
        case .tooLarge:
            Text("This version is too large to show.").padding()
        case .notUTF8:
            Text("This version is not UTF-8 text.").padding()
        case .symlink(let target):
            VStack(alignment: .leading, spacing: 8) {
                Text("This version is a symbolic link and was not followed.")
                Text(target).font(.body.monospaced())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        case .gitlink:
            Text("This version is a submodule.").padding()
        case .directory:
            Text("This version is a directory.").padding()
        case .missingObject:
            Text("The object for this version is missing.").padding()
        }
    }
}

private struct FileBlameList: View {
    let repo: URL
    let path: String
    let revision: Int
    @State private var spans: [BlameSpan]?
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Files", systemImage: "doc", description: Text(error))
            } else if let spans {
                if spans.isEmpty {
                    Text("Nothing to blame in this file.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    List(spans) { span in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                if let commitID = span.commitID {
                                    Text(String(commitID.prefix(7)))
                                        .font(.caption.monospaced())
                                    Text(span.author)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Not committed")
                                        .font(.caption.monospaced())
                                }
                                Spacer(minLength: 8)
                                Text(String(format: String(localized: "Lines %lld–%lld"), span.startLine, span.startLine + max(span.lineCount, 1) - 1))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if span.originPath != path {
                                Text(String(format: String(localized: "Renamed from %@"), span.originPath))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if span.historyLimited {
                                Text("History before this commit was not inspected, so these lines may be older.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let commit = span.commit {
                                NavigationLink("View commit") {
                                    CommitDetailView(repo: repo, commit: commit)
                                }
                            }
                            Text(span.lines.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: revision) {
            do {
                let repo = repo
                let path = path
                let key = BlameQueue.Key(repo: repo.standardizedFileURL.path, path: path, revision: revision)
                let loaded = try await BlameQueue.shared.run(key) { token in
                    try GitClient.blame(at: repo, path: path, cancellation: token)
                }
                guard !Task.isCancelled else { return }
                spans = loaded
                error = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

enum FileInspectionLabels {
    static func change(_ entry: FileHistoryEntry) -> String {
        switch entry.kind {
        case .added: String(localized: "Added")
        case .modified: String(localized: "Modified")
        case .deleted: String(localized: "Deleted")
        case .renamed:
            String(format: String(localized: "Renamed from %@"), entry.previousPath ?? "")
        }
    }
}

private struct SourceTextView: UIViewRepresentable {
    let text: String
    let spans: [SyntaxSpan]

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = true
        view.attributedText = attributed(font: font)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let next = attributed(font: font)
        if view.attributedText != next { view.attributedText = next }
    }

    private var font: UIFont {
        UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
    }

    private func attributed(font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
        ])
        for span in spans {
            let range = NSRange(location: span.location, length: span.length)
            guard range.location >= 0, NSMaxRange(range) <= result.length else { continue }
            result.addAttribute(.foregroundColor, value: color(span.kind), range: range)
        }
        return result
    }

    private func color(_ kind: SyntaxSpan.Kind) -> UIColor {
        switch kind {
        case .keyword: .systemPurple
        case .string: .systemRed
        case .comment: .secondaryLabel
        case .number: .systemTeal
        }
    }
}
