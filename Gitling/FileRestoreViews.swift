import SwiftUI

struct FileStatusActions: View {
    let staged: Bool
    let canRestore: Bool
    let busy: Bool
    let onStage: () -> Void
    let onRestore: () -> Void

    var body: some View {
        AdaptiveActionGroup {
            Button(staged ? String(localized: "Unstage") : String(localized: "Stage"), action: onStage)
            if canRestore {
                Button("Discard Changes…", role: .destructive, action: onRestore)
            }
        }
        .buttonStyle(.bordered)
        .disabled(busy)
    }
}

struct FileRestoreImpact: View {
    let path: String
    let restoresDeletedFile: Bool
    let external: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(path).font(.body.monospaced()).textSelection(.enabled)
            Text("Source: Index (staged version)").font(.headline)
            if restoresDeletedFile {
                Text("Recreate this deleted working file from the index. Staged changes will be kept.")
            } else {
                Text("Replace only this working file with its index version. Its unstaged changes will be lost. Staged changes will be kept.")
            }
            if external {
                Text("This changes the file in your linked external working folder.")
            }
            Text("Other files and the index will not be changed. This action cannot be undone in Gitling.")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FileRestoreConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let plan: FileRestorePlan
    let external: Bool
    let busy: Bool
    let onRestore: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    FileRestoreImpact(path: plan.path, restoresDeletedFile: plan.restoresDeletedFile, external: external)
                    Button("Restore File", role: .destructive, action: onRestore)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
                .padding()
            }
            .navigationTitle(plan.restoresDeletedFile ? String(localized: "Restore Deleted File?") : String(localized: "Discard Unstaged Changes?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
