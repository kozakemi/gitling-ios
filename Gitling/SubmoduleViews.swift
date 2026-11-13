import SwiftUI

struct SubmoduleActions: View {
    let busy: Bool
    let pending: Bool
    let onInitialize: () -> Void
    let onUpdate: () -> Void
    let onResume: () -> Void
    let onEnd: () -> Void

    var body: some View {
        AdaptiveActionGroup {
            if pending {
                Button("Retry Remaining", action: onResume)
                Button("End This Update", action: onEnd)
            } else {
                Button("Initialize Submodules", action: onInitialize)
                Button("Update Submodules", action: onUpdate)
            }
        }
        .buttonStyle(.bordered)
        .disabled(busy)
    }
}

struct SubmodulePage: View {
    @EnvironmentObject private var store: RepoStore
    let name: String
    @State private var snapshot: SubmoduleSnapshot?
    @State private var recursive = false
    @State private var initializeMissing = true
    @State private var loading = true
    @State private var error: String?
    @State private var confirm: SubmoduleAction?
    @State private var confirmEnd = false
    @State private var selectedAccounts: [String: UUID] = [:]
    @State private var selectedSSHKeys: [String: UUID] = [:]
    @State private var overrides: [String: SubmoduleCredentials] = [:]

    private var authorities: [String] {
        Array(Set((snapshot?.items ?? []).compactMap { SubmoduleAuth.authority($0.url) })).sorted()
    }

    var body: some View {
        List {
            Section {
                Toggle("Recursive Submodules", isOn: $recursive).disabled(store.isBusy || snapshot?.checkpoint != nil)
                Toggle("Initialize Missing Submodules", isOn: $initializeMissing).disabled(store.isBusy || snapshot?.checkpoint != nil)
                Text("Initialize saves local configuration without downloading. Update checks out the commits recorded in the parent index, not the latest remote branches.")
                    .foregroundStyle(.secondary)
                SubmoduleActions(busy: store.isBusy || loading, pending: snapshot?.checkpoint != nil,
                                 onInitialize: { confirm = .initialize }, onUpdate: { confirm = .update },
                                 onResume: { run(.update, resume: true) }, onEnd: { confirmEnd = true })
                if let checkpoint = snapshot?.checkpoint {
                    Text(String(format: String(localized: "Completed: %lld"), checkpoint.completed.count))
                    if let path = checkpoint.current { Text(path).font(.body.monospaced()) }
                    Text("A previous update is unfinished. Retry uses its saved options. Ending keeps completed work, downloaded objects, and backup references; it does not roll back files.")
                }
            }
            if !authorities.isEmpty {
                Section("Submodule Credentials") {
                    Text("Each remote uses its own matching account. A saved sign-in for this repository is reused only when the submodule uses the same scheme, host, and port. For SSH remotes on another host, select a key here. Newly discovered nested remotes use matching saved accounts; retry to choose their SSH keys if needed.")
                        .foregroundStyle(.secondary)
                    ForEach(authorities, id: \.self) { authority in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(authority).font(.caption.monospaced()).textSelection(.enabled)
                            if authority.hasPrefix("ssh://") {
                                Picker("SSH Key", selection: Binding(get: { selectedSSHKeys[authority] }, set: { selectedSSHKeys[authority] = $0 })) {
                                    Text("Automatic").tag(UUID?.none)
                                    ForEach(store.sshKeys) { key in Text(key.name).tag(Optional(key.id)) }
                                }
                            } else {
                                Picker("Account", selection: Binding(get: { selectedAccounts[authority] }, set: { selectedAccounts[authority] = $0 })) {
                                    Text("Automatic").tag(UUID?.none)
                                    ForEach(store.accounts.filter { SubmoduleAuth.authority($0.baseURL) == authority }) { account in
                                        Text(account.accountLabel).tag(Optional(account.id))
                                    }
                                }
                                TextField("Username", text: Binding(get: { overrides[authority]?.username ?? "" }, set: {
                                    var value = overrides[authority] ?? .init(); value.username = $0; overrides[authority] = value
                                })).textInputAutocapitalization(.never).autocorrectionDisabled()
                                SecureField("Password or token (optional override)", text: Binding(get: { overrides[authority]?.secret ?? "" }, set: {
                                    var value = overrides[authority] ?? .init(); value.secret = $0; overrides[authority] = value
                                }))
                            }
                        }
                    }
                }.disabled(store.isBusy)
            }
            Section("Submodule Status") {
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
                if let message = store.alert { Text(message).foregroundStyle(.red) }
                if let snapshot, snapshot.items.isEmpty { Text("No submodules") }
                ForEach(snapshot?.items ?? []) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.path).font(.body.monospaced())
                        Text(item.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let problem = item.problem { Text(problem).foregroundStyle(.red) }
                        Text(item.dirty ? String(localized: "Local changes — protected") : !item.initialized ? (item.configured ? String(localized: "Initialized; not checked out") : String(localized: "Not initialized")) : item.needsUpdate ? String(localized: "Needs update") : String(localized: "Up to date"))
                        if let target = item.target { Text(String(format: String(localized: "Index: %@"), String(target.prefix(12)))).font(.caption.monospaced()) }
                        if let head = item.head { Text("HEAD: " + String(head.prefix(12))).font(.caption.monospaced()) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if error != nil && snapshot == nil {
                Button("End This Update") { confirmEnd = true }.disabled(store.isBusy)
            }
        }
        .navigationTitle("Submodules")
        .overlay {
            if store.isBusy, let progress = store.operationProgress {
                OperationProgressOverlay(state: progress)
            }
        }
        .toolbar { if store.isBusy { ProgressView() } }
        .task(id: "\(store.revision)-\(recursive)") { await load() }
        .confirmationDialog(confirm == .initialize ? String(localized: "Initialize Submodules?") : String(localized: "Update Submodules?"), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { action in
            Button("Continue") { run(action); confirm = nil }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: { _ in
            Text("Only submodules are changed. Local modifications block checkout. Updates may download missing commits; successful steps are retained if a later step fails. Linked external working folders are changed in place.")
        }
        .confirmationDialog("End This Update?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End This Update") { store.endSubmoduleUpdate(name: name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep completed work and local Git data, and remove only the saved task. No files are rolled back or deleted.")
        }
    }
    private func run(_ action: SubmoduleAction, resume: Bool = false) {
        store.updateSubmodules(name: name, action: action, recursive: recursive, initializeMissing: initializeMissing, resume: resume,
                               selectedAccounts: selectedAccounts, selectedSSHKeys: selectedSSHKeys, overrides: overrides)
    }
    private func load() async {
        loading = true
        defer { loading = false }
        let url = store.repoURL(name), recursive = recursive
        do {
            let value = try await Task.detached { try GitClient.submodules(at: url, recursive: recursive) }.value
            guard !Task.isCancelled else { return }
            snapshot = value; error = nil
            if let saved = value.checkpoint { self.recursive = saved.recursive; initializeMissing = saved.initializeMissing }
            if let origin = try? GitClient.originURL(url) {
                let split = GitRemoteURL.splitUserInfo(origin)
                if let authority = SubmoduleAuth.authority(split.url),
                   let username = split.username, !username.isEmpty,
                   overrides[authority]?.secret.isEmpty != false,
                   (overrides[authority]?.username ?? "").isEmpty {
                    var prefilled = overrides[authority] ?? .init()
                    prefilled.username = username
                    overrides[authority] = prefilled
                }
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
