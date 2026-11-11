import SwiftUI

struct RepositoryDetailNavigation<Content: View>: View {
    let selection: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack(root: content)
            // Fold/resize preserves state; choosing another repository resets it.
            .id(selection)
    }
}

/// Keep action titles readable when a folded screen, split column or larger text
/// leaves too little room for a single row. This does not depend on device models.
struct AdaptiveActionGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8, content: content)
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8, content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RepositorySectionPicker: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Binding var selection: Int

    var body: some View {
        if textSize >= .xxxLarge {
            picker.pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ViewThatFits(in: .horizontal) {
                picker.pickerStyle(.segmented)
                    .frame(minWidth: 320)
                picker.pickerStyle(.menu)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var picker: some View {
        Picker("Section", selection: $selection) {
            Text("Files").tag(0)
            Text("Commits").tag(1)
            Text("Status").tag(2)
            Text("Console").tag(3)
        }
    }
}
