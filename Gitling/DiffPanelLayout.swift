import SwiftUI

/// Keep the scope control at the top even when the content is an empty/error
/// label rather than a flexible diff view. This fixes the scope-switch jump.
struct DiffPanelLayout<Header: View, Content: View>: View {
    let header: Header
    let content: Content

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct DiffScopePicker: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Binding var scope: GitClient.DiffScope
    var body: some View {
        Group {
            if textSize >= .xxxLarge { picker.pickerStyle(.menu) }
            else {
                ViewThatFits(in: .horizontal) {
                    picker.pickerStyle(.segmented).frame(minWidth: 300)
                    picker.pickerStyle(.menu)
                }
            }
        }.accessibilityIdentifier("diff.scope")
    }
    private var picker: some View {
        Picker("Diff", selection: $scope) {
            Text("Unstaged Changes").tag(GitClient.DiffScope.worktree)
            Text("Staged Changes").tag(GitClient.DiffScope.staged)
        }
    }
}
