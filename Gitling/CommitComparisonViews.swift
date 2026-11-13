// Gitling/CommitComparisonViews.swift
import Combine
import Foundation
import SwiftUI

// MARK: - Shared serial read model

/// One serial queue for comparison list, detail, reference, and resolution reads.
/// Cancelled work that has not started skips immediately; work already inside a
/// synchronous libgit2 call is allowed to return. The token is passed into the
/// backend so its callbacks can abort, and generation guards stop late publication.
private let comparisonReadQueue = DispatchQueue(
    label: "Gitling.commitComparison.read",
    qos: .userInitiated
)

private enum ComparisonLoadOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case cancelled
    case failure(String)
}

@MainActor
final class ComparisonLoadModel<Value: Sendable>: ObservableObject {
    @Published private(set) var value: Value?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private var generation = 0
    private var token: SearchCancellation?

    func cancel() {
        generation += 1
        token?.cancel()
        token = nil
        isLoading = false
        value = nil
        error = nil
    }

    func invalidate(from previousKey: String?, to nextKey: String?) {
        if previousKey != nextKey { cancel() }
    }

    func load(_ work: @escaping @Sendable (SearchCancellation) throws -> Value) async {
        cancel()
        let current = generation
        let token = SearchCancellation()
        self.token = token
        value = nil
        error = nil
        isLoading = true

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ComparisonLoadOutcome<Value>, Never>) in
                comparisonReadQueue.async {
                    // This queued item was superseded before it started.
                    do {
                        try token.check()
                    } catch {
                        continuation.resume(returning: .cancelled)
                        return
                    }
                    do {
                        let value = try work(token)
                        try token.check()
                        continuation.resume(returning: .success(value))
                    } catch is CancellationError {
                        continuation.resume(returning: .cancelled)
                    } catch {
                        continuation.resume(returning: .failure(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            token.cancel()
        }

        guard current == generation else { return }
        isLoading = false
        self.token = nil
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let value):
            self.value = value
        case .cancelled:
            break
        case .failure(let message):
            error = message
        }
    }
}

private struct ComparisonListSnapshot: Sendable {
    let key: String
    let result: ComparisonListResult
}

// MARK: - Comparison page

private enum ComparisonEndpointSelection: String, Identifiable {
    case base, target
    var id: String { rawValue }
}

struct CommitComparisonPage: View {
    let repo: URL

    @State private var base: ComparisonEndpoint?
    @State private var target: ComparisonEndpoint?
    @State private var selecting: ComparisonEndpointSelection?
    @StateObject private var listModel = ComparisonLoadModel<ComparisonListSnapshot>()

    init(repo: URL,
         initialBase: ComparisonEndpoint? = nil,
         initialTarget: ComparisonEndpoint? = nil) {
        self.repo = repo
        _base = State(initialValue: initialBase)
        _target = State(initialValue: initialTarget)
    }

    private var comparisonKey: String? {
        guard let base, let target else { return nil }
        return base.oid + ".." + target.oid
    }

    var body: some View {
        List {
            Section {
                ComparisonEndpointHeader(
                    base: base,
                    target: target,
                    chooseBase: { selecting = .base },
                    chooseTarget: { selecting = .target },
                    swap: swapEndpoints
                )
            } footer: {
                Text("Compares the two fixed commit trees directly. The merge base, index, and working folder are not used. Read-only.")
                    .font(.footnote)
            }

            Section {
                comparisonContent
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Compare Commits")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: comparisonKey) {
            guard let base, let target else {
                listModel.cancel()
                return
            }
            let comparison = CommitComparison(base: base, target: target)
            await listModel.load { token in
                ComparisonListSnapshot(key: comparison.id, result: try GitClient.comparisonFiles(at: repo, comparison: comparison, cancellation: token))
            }
        }
        .onDisappear { listModel.cancel() }
        .sheet(item: $selecting) { selection in
            ComparisonEndpointPicker(
                repo: repo,
                title: selection == .base
                    ? String(localized: "Choose Base")
                    : String(localized: "Choose Target")
            ) { endpoint in
                switch selection {
                case .base:
                    listModel.invalidate(from: comparisonKey, to: target.map { endpoint.oid + ".." + $0.oid })
                    base = endpoint
                case .target:
                    listModel.invalidate(from: comparisonKey, to: base.map { $0.oid + ".." + endpoint.oid })
                    target = endpoint
                }
            }
        }
    }

    private func swapEndpoints() {
        guard let base, let target else { return }
        listModel.invalidate(from: comparisonKey, to: target.oid + ".." + base.oid)
        self.base = target
        self.target = base
    }

    @ViewBuilder
    private var comparisonContent: some View {
        if let base, let target {
            if listModel.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Comparing commits…")
                        .foregroundStyle(.secondary)
                }
            } else if let error = listModel.error {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let snapshot = listModel.value, snapshot.key == comparisonKey {
                let result = snapshot.result
                if base.oid == target.oid {
                    Text("The base and target are the same commit.")
                        .foregroundStyle(.secondary)
                } else if result.files.isEmpty {
                    Text("No changed files between these commits.")
                        .foregroundStyle(.secondary)
                }

                if result.truncated {
                    Label(
                        "Only the first \(result.limits.maximumFiles) files are shown because the file-list budget was reached.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if result.limitsReached.contains(.renameCandidates) {
                    Label(
                        "Rename detection was skipped because candidates were unavailable or exceeded the resource budget.",
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if base.oid != target.oid && !result.files.isEmpty {
                    ForEach(result.files) { file in
                        NavigationLink {
                            ComparisonFileDetailPage(
                                repo: repo,
                                comparison: CommitComparison(base: base, target: target),
                                file: file
                            )
                        } label: {
                            ComparisonFileRow(file: file)
                        }
                        .accessibilityIdentifier("comparison.file")
                    }
                }
            } else {
                Text("Preparing comparison…")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Choose a base and target commit to compare.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Reusable endpoint header

struct ComparisonEndpointHeader: View {
    let base: ComparisonEndpoint?
    let target: ComparisonEndpoint?
    let chooseBase: () -> Void
    let chooseTarget: () -> Void
    let swap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            endpoint(base,
                     title: String(localized: "Base commit"),
                     identifier: "comparison.base",
                     action: chooseBase)

            Image(systemName: "arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityHidden(true)

            endpoint(target,
                     title: String(localized: "Target commit"),
                     identifier: "comparison.target",
                     action: chooseTarget)

            Button(action: swap) {
                Label("Swap Base and Target", systemImage: "arrow.up.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(base == nil || target == nil)
            .accessibilityIdentifier("comparison.swap")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func endpoint(_ endpoint: ComparisonEndpoint?,
                          title: String,
                          identifier: String,
                          action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: action) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 8)
                    Text(endpoint?.input ?? String(localized: "Choose a commit"))
                        .font(.body.monospaced())
                        .foregroundStyle(endpoint == nil ? Color.secondary : Color.primary)
                        .multilineTextAlignment(.trailing)
                        .layoutPriority(1)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)

            if let endpoint {
                Text(endpoint.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(endpoint.oid)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Endpoint picker

private struct ComparisonSearchRequest: Equatable {
    let query: String
    let field: CommitSearchField
}

private struct ComparisonEndpointPicker: View {
    let repo: URL
    let title: String
    let onSelect: (ComparisonEndpoint) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var referencesModel = ComparisonLoadModel<[ComparisonReference]>()
    @StateObject private var searchModel = RepositorySearchModel<CommitInfo>()
    @StateObject private var resolveModel = ComparisonLoadModel<ComparisonEndpoint>()

    @State private var input = ""
    @State private var query = ""
    @State private var field = CommitSearchField.all
    @State private var resolveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Branch, tag, HEAD, or OID prefix", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("comparison.reference")

                    Button {
                        resolve(input)
                    } label: {
                        Label("Resolve", systemImage: "arrow.right.circle")
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || resolveModel.isLoading)
                    .accessibilityIdentifier("comparison.resolve")

                    if let error = resolveModel.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if resolveModel.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Resolving…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Commit or reference")
                } footer: {
                    Text("A branch or tag is resolved once to a full commit OID. Moving it later does not change the comparison.")
                        .font(.footnote)
                }

                Section {
                    Picker("Search field", selection: $field) {
                        ForEach(CommitSearchField.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.menu)

                    RepositoryQueryField(query: $query, prompt: "Message, author, or OID prefix")

                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Enter a query to search all history.")
                            .foregroundStyle(.secondary)
                    } else {
                        RepositorySearchStatus(
                            loading: searchModel.isLoading,
                            count: searchModel.items.count,
                            scanned: searchModel.scanned,
                            hasMore: searchModel.hasMore
                        )
                        if !searchModel.isLoading && searchModel.error == nil && searchModel.items.isEmpty {
                            Text("No matching commits")
                                .foregroundStyle(.secondary)
                        }
                        if let error = searchModel.error {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(searchModel.items) { commit in
                            Button {
                                resolve(commit.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(commit.summary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(commit.author + " · " + commit.date.formatted())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(String(commit.id.prefix(12)))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .disabled(resolveModel.isLoading)
                        }
                        if searchModel.hasMore {
                            Button("Load More Results") {
                                Task { await searchModel.loadMore() }
                            }
                            .disabled(searchModel.isLoading)
                        }
                    }
                } header: {
                    Text("Search all history")
                } footer: {
                    Text("Searches the complete reachable history beyond the commits already loaded in this repository.")
                        .font(.footnote)
                }
                Section {
                    if referencesModel.isLoading && referencesModel.value == nil {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading references…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = referencesModel.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let references = referencesModel.value {
                        ForEach(references) { reference in
                            Button {
                                resolve(reference.reference)
                            } label: {
                                referenceLabel(reference)
                            }
                            .disabled(resolveModel.isLoading)
                        }
                    }
                } header: {
                    Text("Branches and tags")
                }

            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            await referencesModel.load { token in
                try GitClient.comparisonReferences(at: repo, cancellation: token)
            }
        }
        .task(id: ComparisonSearchRequest(query: query, field: field)) {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                searchModel.cancel()
                return
            }
            let query = query, field = field, repo = repo
            await searchModel.search { token in
                try GitClient.historySearch(at: repo, query: query, field: field,
                                            scope: .all, cancellation: token)
            }
        }
        .onChange(of: input) { _, _ in cancelResolution() }
        .onChange(of: query) { _, _ in cancelResolution() }
        .onChange(of: field) { _, _ in cancelResolution() }
        .onDisappear {
            referencesModel.cancel()
            searchModel.cancel()
            resolveTask?.cancel()
            resolveModel.cancel()
        }
    }

    private func referenceLabel(_ reference: ComparisonReference) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(reference.name)
                    .font(.body.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                if reference.annotated {
                    Text("Annotated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if reference.isCurrent {
                    Text("Current")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(referenceKindTitle(reference.kind) + " · " + reference.reference)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func referenceKindTitle(_ kind: ComparisonReference.Kind) -> String {
        switch kind {
        case .head: return String(localized: "HEAD")
        case .localBranch: return String(localized: "Local branch")
        case .remoteBranch: return String(localized: "Remote branch")
        case .tag: return String(localized: "Tag")
        }
    }

    @MainActor
    private func cancelResolution() {
        resolveTask?.cancel()
        resolveModel.cancel()
    }

    @MainActor
    private func resolve(_ raw: String) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        resolveTask?.cancel()
        resolveTask = Task {
            await resolveModel.load { token in
                try GitClient.resolveComparisonCommit(at: repo, input: input, cancellation: token)
            }
            guard !Task.isCancelled, let endpoint = resolveModel.value else { return }
            onSelect(endpoint)
            dismiss()
        }
    }
}

// MARK: - File row

private struct ComparisonFileRow: View {
    let file: ComparisonFile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(changeTitle(file.change))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let similarity = file.similarity, file.change == .renamed {
                    Text(String(format: String(localized: "%lld%% similar"), similarity))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(file.displayPath)
                .font(.body.monospaced())
                .fixedSize(horizontal: false, vertical: true)
            if let oldMode = file.oldMode, let newMode = file.newMode, oldMode != newMode {
                Text(String(format: String(localized: "Mode %@ → %@"),
                            modeString(oldMode), modeString(newMode)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func changeTitle(_ kind: ComparisonChangeKind) -> String {
        switch kind {
        case .added: return String(localized: "Added")
        case .deleted: return String(localized: "Deleted")
        case .modified: return String(localized: "Modified")
        case .renamed: return String(localized: "Renamed")
        case .typeChanged: return String(localized: "Type changed")
        case .modeChanged: return String(localized: "Mode changed")
        case .other: return String(localized: "Changed")
        }
    }

    private func modeString(_ mode: UInt32) -> String {
        String(mode, radix: 8)
    }
}

// MARK: - Single-file detail

private struct ComparisonFileDetailPage: View {
    let repo: URL
    let comparison: CommitComparison
    let file: ComparisonFile

    @StateObject private var model = ComparisonLoadModel<ComparisonFileDiff>()

    var body: some View {
        GeometryReader { proxy in
            DiffPanelLayout {
                ComparisonHeaderViewport(maximumHeight: max(96, min(260, proxy.size.height * 0.42))) {
                    fileHeader(model.value?.file.id == file.id ? model.value!.file : file)
                }
            } content: {
                diffContent
            }
        }
        .navigationTitle(file.path.isEmpty ? String(localized: "File") : file.path)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: file.id) {
            let repo = repo, comparison = comparison, file = file
            await model.load { token in
                try GitClient.comparisonFileDiff(at: repo, comparison: comparison,
                                                 file: file, cancellation: token)
            }
        }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var diffContent: some View {
        if model.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error {
            ScrollView {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        } else if let diff = model.value, diff.file.id == file.id {
            switch diff.content {
            case .patch(let patch):
                VStack(alignment: .leading, spacing: 6) {
                    patchSummary(patch)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    DiffTextView(text: patch.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .binary:
                stateView(icon: "doc",
                          title: String(localized: "Binary file"),
                          message: String(localized: "Binary content is not shown."))
            case .notUTF8:
                stateView(icon: "textformat",
                          title: String(localized: "Not UTF-8 text"),
                          message: String(localized: "Non-UTF-8 content is not previewed."))
            case .tooLarge(let oldBytes, let newBytes):
                stateView(
                    icon: "exclamationmark.triangle",
                    title: String(localized: "File is too large"),
                    message: String(
                        format: String(localized: "At least one side exceeds the comparison size limit. Base: %@ · Target: %@"),
                        byteLabel(oldBytes), byteLabel(newBytes)
                    )
                )
            case .missingObject:
                stateView(icon: "questionmark.folder",
                          title: String(localized: "Object missing"),
                          message: String(localized: "The selected object is missing from this repository."))
            case .directory:
                stateView(icon: "folder",
                          title: String(localized: "Directory"),
                          message: String(localized: "A directory entry changed instead of a file."))
            case .gitlink(let oldOID, let newOID):
                gitlinkView(oldOID, newOID)
            case .symlink(let oldTarget, let newTarget):
                symlinkView(oldTarget, newTarget)
            case .unchanged:
                stateView(icon: "equal.circle",
                          title: String(localized: "Unchanged"),
                          message: String(localized: "The file content and mode are unchanged."))
            }
        } else {
            Text("Preparing comparison…")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
    }

    private func fileHeader(_ file: ComparisonFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.displayPath)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: String(localized: "Base %@"), comparison.base.oid))
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: String(localized: "Target %@"), comparison.target.oid))
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: String(localized: "Mode %@ → %@"),
                        modeLabel(file.oldMode), modeLabel(file.newMode)))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: String(localized: "Base: %@ · Target: %@"),
                        contentLabel(file.oldContent), contentLabel(file.newContent)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func patchSummary(_ patch: ComparisonPatch) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: String(localized: "%lld additions · %lld deletions"),
                        patch.insertions, patch.deletions))
                .font(.caption)
                .foregroundStyle(.secondary)
            if patch.truncated {
                Label(
                    "Patch truncated at the patch budget. Addition and deletion counts are partial.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stateView(icon: String, title: String, message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private func gitlinkView(_ oldOID: String?, _ newOID: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("Submodule gitlink", systemImage: "shippingbox")
                    .font(.headline)
                Text("Only the recorded commit OIDs are shown; the submodule is not updated or opened.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let oldOID {
                    Text(String(format: String(localized: "Base %@"), oldOID))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let newOID {
                    Text(String(format: String(localized: "Target %@"), newOID))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private func symlinkView(_ oldTarget: String?, _ newTarget: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("Symbolic link", systemImage: "link")
                    .font(.headline)
                Text("Only the recorded link target is shown; the target is not followed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let oldTarget {
                    Text(String(format: String(localized: "Base link target: %@"), oldTarget))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let newTarget {
                    Text(String(format: String(localized: "Target link target: %@"), newTarget))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private func modeLabel(_ mode: UInt32?) -> String {
        mode.map { String($0, radix: 8) } ?? "—"
    }

    private func byteLabel(_ bytes: Int?) -> String {
        guard let bytes else { return String(localized: "not applicable") }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func contentLabel(_ kind: ComparisonContentKind) -> String {
        switch kind {
        case .unknown: return String(localized: "Unknown")
        case .text: return String(localized: "Text")
        case .binary: return String(localized: "Binary")
        case .symlink: return String(localized: "Symbolic link")
        case .gitlink: return String(localized: "Submodule")
        case .tooLarge: return String(localized: "Too large")
        case .notUTF8: return String(localized: "Not UTF-8")
        case .missing: return String(localized: "Missing")
        case .directory: return String(localized: "Directory")
        }
    }
}

// Keep long paths/OIDs and large accessibility text scrollable without pushing the
// entire diff body off the screen. Short headers retain their intrinsic height.
private struct ComparisonHeaderHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ComparisonHeaderViewport<Content: View>: View {
    let maximumHeight: CGFloat
    let content: Content
    @State private var measured: CGFloat
    init(maximumHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maximumHeight = maximumHeight
        self.content = content()
        _measured = State(initialValue: maximumHeight)
    }
    var body: some View {
        ScrollView {
            content.frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ComparisonHeaderHeight.self, value: proxy.size.height)
                })
        }
        .frame(height: min(maximumHeight, max(1, measured)))
        .onPreferenceChange(ComparisonHeaderHeight.self) { if $0 > 0 { measured = $0 } }
        .accessibilityIdentifier("comparison.header")
    }
}
