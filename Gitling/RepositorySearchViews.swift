import SwiftUI

struct RepositoryQueryField: View {
    @Binding var query: String
    let prompt: LocalizedStringKey
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focused).submitLabel(.search)
                .onSubmit { focused = false }
                .accessibilityIdentifier("repository.search.query")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
    }
}

struct RepositorySearchStatus: View {
    let loading: Bool
    let count: Int
    let scanned: Int
    let hasMore: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if loading { Label { Text("Searching…") } icon: { ProgressView() } }
            else {
                Text(String(format: String(localized: "%lld results shown · %lld entries checked"), count, scanned))
                if hasMore { Text("More matches are available. Load the next page to continue.") }
            }
        }
        .font(.footnote).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct HistorySearchFilters: View {
    @Binding var field: CommitSearchField
    @Binding var scope: HistorySearchScope
    let selectedReference: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Search field", selection: $field) {
                ForEach(CommitSearchField.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
            Picker("History scope", selection: $scope) {
                Text("Current HEAD").tag(HistorySearchScope.current)
                Text("All branches and tags").tag(HistorySearchScope.all)
                if let selectedReference { Text(selectedReference).tag(HistorySearchScope.reference(selectedReference)) }
            }.pickerStyle(.menu)
        }
    }
}

private struct HistorySearchRequest: Equatable {
    let query: String
    let field: CommitSearchField
    let scope: HistorySearchScope
    let revision: Int
}

struct HistorySearchPage: View {
    @EnvironmentObject private var store: RepoStore
    let repo: URL
    let selectedReference: String?
    @State private var query = ""
    @State private var field = CommitSearchField.all
    @State private var scope: HistorySearchScope
    @StateObject private var model = RepositorySearchModel<CommitInfo>()
    init(repo: URL, scope: HistorySearchScope = .all, selectedReference: String? = nil) {
        self.repo = repo; self.selectedReference = selectedReference
        _scope = State(initialValue: scope)
    }
    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                RepositoryQueryField(query: $query, prompt: "Message, author, or OID prefix")
                HistorySearchFilters(field: $field, scope: $scope, selectedReference: selectedReference)
                Text("Searches the complete reachable history in this scope, including pages not loaded.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(.horizontal).padding(.top, 8)
            List {
                if let error = model.error { Text(error).foregroundStyle(.red) }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("Enter a query to search history.").foregroundStyle(.secondary) }
                else {
                    RepositorySearchStatus(loading: model.isLoading, count: model.items.count, scanned: model.scanned, hasMore: model.hasMore)
                    if !model.isLoading && model.error == nil && model.items.isEmpty { Text("No matching commits") }
                }
                ForEach(model.items) { commit in
                    NavigationLink {
                        CommitDetailView(repo: repo, commit: commit)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(commit.summary)
                            Text(commit.author + " · " + commit.date.formatted()).font(.caption).foregroundStyle(.secondary)
                            Text(String(commit.id.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.hasMore {
                    Button("Load More Results") { Task { await model.loadMore() } }.disabled(model.isLoading)
                }
            }.listStyle(.insetGrouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Search History")
        .task(id: HistorySearchRequest(query: query, field: field, scope: scope, revision: store.revision)) {
            let query = query, field = field, scope = scope, repo = repo
            await model.search { token in try GitClient.historySearch(at: repo, query: query, field: field, scope: scope, cancellation: token) }
        }
        .onDisappear { model.cancel() }
    }
}

private struct FileSearchRequest: Equatable { let query: String; let revision: Int }

struct FileSearchPage: View {
    @EnvironmentObject private var store: RepoStore
    let repo: URL
    @State private var query = ""
    @StateObject private var model = RepositorySearchModel<WorkEntry>()
    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                RepositoryQueryField(query: $query, prompt: "File name or relative path")
                Text("Searches files throughout the working folder, including hidden and untracked files. Git metadata and symbolic links are excluded.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(.horizontal).padding(.top, 8)
            List {
                if let error = model.error { Text(error).foregroundStyle(.red) }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("Enter a query to search files.").foregroundStyle(.secondary) }
                else {
                    RepositorySearchStatus(loading: model.isLoading, count: model.items.count, scanned: model.scanned, hasMore: model.hasMore)
                    if !model.isLoading && model.error == nil && model.items.isEmpty { Text("No matching files") }
                }
                ForEach(model.items) { entry in
                    NavigationLink {
                        FilePreview(repo: repo, relative: entry.path, name: entry.name)
                    } label: {
                        Label { Text(entry.path).font(.body.monospaced()) } icon: { Image(systemName: "doc.text") }
                    }
                }
                if model.hasMore {
                    Button("Load More Results") { Task { await model.loadMore() } }.disabled(model.isLoading)
                }
            }.listStyle(.insetGrouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Search Files")
        .task(id: FileSearchRequest(query: query, revision: store.revision)) {
            let query = query, repo = repo
            await model.search { token in try GitClient.fileSearch(at: repo, query: query, cancellation: token) }
        }
        .onDisappear { model.cancel() }
    }
}
