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

/// The four repository sections, in the same order as the picker. A horizontal
/// swipe in the content area changes the selection; the picker stays in sync.
struct RepositorySectionPages<Files: View, Commits: View, Status: View, Terminal: View>: View {
    @Binding var selection: Int
    var pagingEnabled: Bool
    var files: Files
    var commits: Commits
    var status: Status
    var terminal: Terminal

    var body: some View {
        TabView(selection: $selection) {
            files.tag(0)
            commits.tag(1)
            status.tag(2)
            terminal.tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background { RepositoryPagingGate(enabled: pagingEnabled) }
        .accessibilityIdentifier("repository.sections")
    }
}

/// Finds the page scroller created for the section tabs and turns horizontal
/// paging on or off without replacing the pages.
struct RepositoryPagingGate: UIViewRepresentable {
    var enabled: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = "repository.sections.gate"
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let scroller = Self.pagingScroller(from: view) else { return }
            if scroller.isScrollEnabled != enabled { scroller.isScrollEnabled = enabled }
        }
    }

    static func pagingScroller(from view: UIView) -> UIScrollView? {
        var node: UIView? = view
        for _ in 0..<14 {
            guard let current = node else { return nil }
            if let found = findPager(in: current, depth: 5) { return found }
            node = current.superview
        }
        return nil
    }

    private static func findPager(in view: UIView, depth: Int) -> UIScrollView? {
        if let scroller = view as? UIScrollView, isHorizontalPager(scroller) { return scroller }
        guard depth > 0 else { return nil }
        for child in view.subviews {
            if let found = findPager(in: child, depth: depth - 1) { return found }
        }
        return nil
    }

    private static func isHorizontalPager(_ scroller: UIScrollView) -> Bool {
        scroller.bounds.width > 1 && scroller.contentSize.width > scroller.bounds.width + 1
            && scroller.contentSize.height <= scroller.bounds.height + 1
    }
}

/// Tab changes on the selector work even when the content owns horizontal
/// scrolling (source, diff, Markdown tables, images). Vertical drags do nothing.
enum SectionSwipe {
    static func destination<Value: Equatable>(from value: Value, values: [Value], translation: CGSize) -> Value? {
        guard abs(translation.width) >= 60, abs(translation.width) > abs(translation.height) * 1.5,
              let current = values.firstIndex(of: value) else { return nil }
        let next = current + (translation.width < 0 ? 1 : -1)
        return values.indices.contains(next) ? values[next] : nil
    }
}
extension View {
    func swipeSelection<Value: Hashable>(_ selection: Binding<Value>, values: [Value]) -> some View {
        highPriorityGesture(DragGesture(minimumDistance: 30).onEnded { gesture in
            if let next = SectionSwipe.destination(from: selection.wrappedValue, values: values, translation: gesture.translation) {
                selection.wrappedValue = next
            }
        })
    }
}

/// Keep heavy Git/preview work lazy. Only the selected destination starts its
/// readers; adjacent pages don't load history/blame or decode media in advance.
struct LazySectionPages<Value: Hashable, Content: View>: View {
    @Binding var selection: Value
    let values: [Value]
    @ViewBuilder var content: (Value) -> Content
    var body: some View {
        TabView(selection: $selection) {
            ForEach(values, id: \.self) { value in
                Group {
                    if selection == value { content(value) }
                    else { Color.clear }
                }.tag(value)
            }
        }.tabViewStyle(.page(indexDisplayMode: .never))
    }
}
