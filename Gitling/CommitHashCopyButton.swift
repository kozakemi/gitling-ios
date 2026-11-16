import SwiftUI
import UIKit

@MainActor enum CommitClipboard {
    nonisolated static func isFullOID(_ oid: String) -> Bool {
        (oid.utf8.count == 40 || oid.utf8.count == 64) && oid.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
    @discardableResult static func copy(_ oid: String, to pasteboard: UIPasteboard? = nil) -> Bool {
        guard isFullOID(oid) else { return false }
        (pasteboard ?? .general).string = oid
        return true
    }
}

/// Always copies the fixed full OID, even when the visual label is abbreviated.
/// No repository lookup or diff loading is needed for a clipboard operation.
struct CommitHashCopyButton: View {
    let oid: String
    var full = false
    var iconOnly = false
    @State private var copied = false
    var body: some View {
        Button {
            copied = CommitClipboard.copy(oid)
        } label: {
            if iconOnly {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                Label {
                    if copied { Text("Commit hash copied") }
                    else { Text(full ? oid : String(oid.prefix(7))).monospaced() }
                } icon: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.borderless)
        .disabled(!CommitClipboard.isFullOID(oid))
        .accessibilityLabel(copied ? Text("Commit hash copied") : Text("Copy commit hash"))
        .accessibilityValue(oid)
        .accessibilityIdentifier("commit.copyHash.\(oid)")
        .help("Copy commit hash")
        .onChange(of: oid) { _, _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }
}
