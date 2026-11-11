import SwiftUI

struct DetachedHeadNotice: View {
    let oid: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(format: String(localized: "Detached HEAD · %@"), String(oid.prefix(12))), systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text("New commits here do not belong to a branch. Create a branch to keep your work.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TagsPage: View {
    @EnvironmentObject private var store: RepoStore
    let name: String
    @State private var tags: [TagInfo] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?

    private var filtered: [TagInfo] { tags.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        List {
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.secondary) }
            if !loading && tags.isEmpty && error == nil { Text("No tags") }
            ForEach(filtered) { tag in
                NavigationLink {
                    TagDetailPage(name: name, tagName: tag.name)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tag.name).font(.body.monospaced())
                        if tag.problem == nil {
                            Text(tag.annotated ? String(localized: "Annotated tag") : String(localized: "Lightweight tag"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let problem = tag.problem { Text(problem).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
        }
        .navigationTitle("Tags")
        .searchable(text: $query, prompt: "Search tags")
        .task(id: store.revision) {
            loading = true
            defer { loading = false }
            let url = store.repoURL(name)
            do {
                let result = try await Task.detached { try GitClient.tags(at: url) }.value
                guard !Task.isCancelled else { return }
                tags = result; error = nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct TagCheckoutImpact: View {
    let tag: String
    let oid: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tag).font(.body.monospaced()).textSelection(.enabled)
            Text(oid).font(.caption.monospaced()).textSelection(.enabled)
            Text("Checking out a tag enters detached HEAD. Branches and tags will not move. Commit or stash all local changes first, including untracked files.")
            Text("Submodules are not automatically updated. New commits will not belong to a branch until you create one.")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TagDetailPage: View {
    @EnvironmentObject private var store: RepoStore
    let name: String
    let tagName: String
    @State private var detail: TagDetail?
    @State private var error: String?
    @State private var loading = true
    @State private var confirm = false
    @State private var checkoutError: String?
    @State private var detachedOID: String?

    var body: some View {
        List {
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let detachedOID {
                Section {
                    DetachedHeadNotice(oid: detachedOID)
                    NavigationLink("Create Branch to Keep Work") { DetachedBranchPage(name: name) }
                }
            }
            if let detail {
                Section("Tag Details") {
                    Text(detail.tag.name).font(.body.monospaced()).textSelection(.enabled)
                    Text(detail.tag.annotated ? String(localized: "Annotated tag") : String(localized: "Lightweight tag"))
                    Text(detail.tag.referenceOID).font(.caption.monospaced()).textSelection(.enabled)
                    if let tagger = detail.tagger { Text(tagger) }
                    if let date = detail.tagDate { Text(date.formatted()) }
                    if let message = detail.message { Text(message).textSelection(.enabled) }
                }
                Section("Target") {
                    Text(detail.targetType).font(.caption.monospaced())
                    Text(detail.targetOID).font(.caption.monospaced()).textSelection(.enabled)
                    if let commit = detail.commit {
                        Text(commit.summary).textSelection(.enabled)
                        Text(commit.author).foregroundStyle(.secondary)
                        Text(commit.date.formatted()).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TagCheckoutImpact(tag: detail.tag.name, oid: detail.targetOID)
                    if let checkoutError { Text(checkoutError).foregroundStyle(.red) }
                    Button("Check Out Tag") { checkoutError = nil; confirm = true }
                        .disabled(!detail.canCheckout || store.isBusy)
                    if !detail.canCheckout { Text("Only tags pointing to commits can be checked out.").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Tag Details")
        .sheet(isPresented: $confirm) {
            if let detail {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            TagCheckoutImpact(tag: detail.tag.name, oid: detail.targetOID)
                            Button("Check Out Tag") {
                                confirm = false
                                store.checkoutTag(name: name, detail: detail) { checkoutError = $0 }
                            }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.isBusy)
                        }.padding()
                    }
                    .navigationTitle("Check Out Tag?")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirm = false } } }
                }.presentationDetents([.medium, .large])
            }
        }
        .task(id: store.revision) {
            loading = true
            defer { loading = false }
            let url = store.repoURL(name), tagName = tagName
            do {
                let value = try await Task.detached { (try GitClient.tagDetail(at: url, name: tagName), try GitClient.header(at: url).detachedOID) }.value
                guard !Task.isCancelled else { return }
                detail = value.0; detachedOID = value.1; error = nil
            } catch { if !Task.isCancelled { detail = nil; self.error = error.localizedDescription } }
        }
    }
}

struct DetachedBranchPage: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var branch = ""
    var body: some View {
        Form {
            Text("Create a branch at the current commit to keep your work.")
            TextField("Branch name", text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Create Branch") { store.createBranch(name: name, branch: branch); dismiss() }
                .disabled(store.isBusy || !GitClient.isValidBranchName(branch))
        }.navigationTitle("Create Branch")
    }
}
