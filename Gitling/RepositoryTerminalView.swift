import SwiftUI
import SwiftTerm
import GitlingIsh

enum TerminalFont {
    static let storageKey = "terminal.fontSize"
    static let minimum = 10.0
    static let maximum = 24.0
    static let fallback = 10.0
    static func clamped(_ value: Double) -> Double { min(max(value, minimum), maximum) }
}

@MainActor final class RepositoryTerminalModel: ObservableObject {
    enum Phase { case stopped, starting, running, suspended, stopping }
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var requiresRestart = false
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    @Published private(set) var nativeAccessReady = true
    var active: Bool { phase != .stopped }
    // A page may be unloaded by TabView. Keep the same emulator and scrollback.
    var surface: TerminalView?
    private var job: TerminalSessionJob?
    private var started = false
    private var rows = 24, cols = 80
    private var visible = true, foreground = true
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var didFinish: ((Bool) -> Void)?
    deinit {
        job?.cancel()
        let identifier = backgroundTask
        if identifier != .invalid {
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(identifier) }
        }
    }

    func ensureStarted(repo: URL, visible: Bool) {
        setTerminalVisible(visible)
        guard !started else { return }
        started = true
        start(repo: repo)
    }
    func start(repo: URL) {
        guard !active, !requiresRestart else { return }
        let invocation = TerminalSessionJob()
        job = invocation
        invocation.suspend(!visible || !foreground)
        phase = .starting; nativeAccessReady = false; error = nil
        status = String(localized: "Preparing Git…")
        let scopeDidFinish = didFinish
        invocation.run(repo: repo, rows: rows, cols: cols, output: { [weak self] data in
            DispatchQueue.main.sync {
                guard let self, self.job === invocation else { return }
                if self.phase == .starting { self.phase = .running; self.status = nil }
                invocation.suspend(!self.visible || !self.foreground)
                // Create the emulator even before its tab first becomes visible.
                self.terminalSurface().feed(byteArray: Array(data)[...])
            }
        }, suspension: { [weak self] paused in
            DispatchQueue.main.sync {
                guard let self, self.job === invocation else { return }
                self.nativeAccessReady = paused && self.phase != .stopping
                if self.phase != .stopping { self.phase = paused ? .suspended : .running }
                self.status = nil
                if paused { self.endBackgroundTask() }
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                let safe: Bool
                if case .failure(let error)? = result { safe = (error as? TerminalRuntime.Failure)?.retainLease != true }
                else { safe = true }
                guard let self, self.job === invocation else { scopeDidFinish?(safe); return }
                self.phase = .stopped; self.status = nil
                self.endBackgroundTask()
                if let result {
                    switch result {
                    case .failure(let error):
                        self.requiresRestart = (error as? TerminalRuntime.Failure)?.retainLease == true || (error as? TerminalRuntime.Failure)?.restartRequired == true
                        self.error = error.localizedDescription
                    case .success(let code):
                        if code < 0 { self.error = String(localized: "Could not start the offline shell.") + " (\(code))" }
                        else if code != 0 && code != 130 && code != 137 { self.error = String(localized: "Shell exited.") + " (\(code))" }
                    }
                }
                self.nativeAccessReady = safe
                _ = self.surface?.resignFirstResponder()
                self.job = nil
                scopeDidFinish?(safe)
            }
        })
    }
    func setTerminalVisible(_ value: Bool) {
        visible = value
        if value && foreground && active { nativeAccessReady = false }
        job?.suspend(!visible || !foreground)
        if !value { _ = surface?.resignFirstResponder() }
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if !value && active && phase != .suspended { beginBackgroundTask() }
        if value && visible && active { nativeAccessReady = false }
        job?.suspend(!visible || !foreground)
    }
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Park repository shell") { [weak self] in
            self?.job?.cancel()
            self?.endBackgroundTask()
        }
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
    func stop() {
        guard active, phase != .stopping else { return }
        phase = .stopping; nativeAccessReady = false
        beginBackgroundTask(); job?.cancel()
    }
    func interrupt() {
        guard phase == .running, let id = job?.token else { return }
        TerminalRuntime.input.async { _ = gp_ish_interrupt(id) }
    }
    func send(_ data: ArraySlice<UInt8>) {
        guard phase == .running, visible, foreground, let id = job?.token else { return }
        let bytes = Array(data)
        TerminalRuntime.input.async {
            for offset in stride(from: 0, to: bytes.count, by: 4096) {
                let chunk = Array(bytes[offset..<min(offset + 4096, bytes.count)])
                if chunk.withUnsafeBufferPointer({ gp_ish_write(id, $0.baseAddress, $0.count) }) != 0 { break }
            }
        }
    }
    func resize(rows: Int, cols: Int) {
        self.rows = max(1, min(rows, 1000)); self.cols = max(1, min(cols, 1000))
        guard active, let id = job?.token else { return }
        let r = self.rows, c = self.cols
        TerminalRuntime.input.async { _ = gp_ish_resize(id, UInt32(r), UInt32(c)) }
    }
    func terminalSurface() -> TerminalView {
        if let surface { return surface }
        let view = PagedTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: CGFloat(TerminalFont.fallback), weight: .regular))
        surface = view
        return view
    }
}

struct RepositoryTerminalView: View {
    let repo: URL
    @ObservedObject var model: RepositoryTerminalModel
    @AppStorage(TerminalFont.storageKey) private var storedFontSize = TerminalFont.fallback
    @State private var showFontSize = false
    @AppStorage(TerminalEnvironmentStore.pendingKey) private var resetPending = false
    private var fontSize: CGFloat { CGFloat(TerminalFont.clamped(storedFontSize)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            buttons
            if resetPending { Text("Close Gitling and reopen it to finish resetting the terminal.").font(.footnote) }
            if model.phase == .starting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.status ?? String(localized: "Preparing Git…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("terminal.preparing")
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TerminalSurface(model: model, fontSize: fontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
        .onDisappear { _ = model.surface?.resignFirstResponder() }
        .sheet(isPresented: $showFontSize) {
            TerminalFontSizeSheet(size: $storedFontSize)
        }
    }
    private var buttons: some View {
        HStack(spacing: 14) {
            if model.active {
                Button(model.phase == .stopping ? "Stopping…" : "Stop Shell") { model.stop() }
                    .disabled(model.phase == .stopping).accessibilityIdentifier("terminal.stop")
            }
            Spacer(minLength: 8)
            Button { showFontSize = true } label: { Image(systemName: "textformat.size") }
                .accessibilityIdentifier("terminal.font")
                .accessibilityLabel(Text("Terminal Text Size"))
        }.font(.subheadline)
    }
}

struct TerminalFontSizeSheet: View {
    @Binding var size: Double
    @Environment(\.dismiss) private var dismiss
    private var pointSize: CGFloat { CGFloat(TerminalFont.clamped(size)) }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TerminalFontPreview(size: pointSize)
                    .frame(maxWidth: .infinity, minHeight: pointSize * 2.4, alignment: .leading)
                HStack(spacing: 12) {
                    Image(systemName: "textformat.size.smaller").accessibilityHidden(true)
                    Slider(value: $size, in: TerminalFont.minimum...TerminalFont.maximum, step: 1)
                        .accessibilityIdentifier("terminal.font.slider")
                        .accessibilityLabel(Text("Terminal Text Size"))
                    Image(systemName: "textformat.size.larger").accessibilityHidden(true)
                }
                Text("\(Int(pointSize)) pt")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("terminal.font.value")
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Terminal Text Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(280), .medium])
    }
}

/// Live sample of the terminal face. The label is the same monospaced font the
/// PTY uses, so dragging the slider changes this preview immediately.
struct TerminalFontPreview: UIViewRepresentable {
    var size: CGFloat
    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = "terminal.font.preview"
        label.text = "/shared $ git status"
        label.adjustsFontForContentSizeCategory = false
        label.backgroundColor = .secondarySystemGroupedBackground
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.textAlignment = .left
        apply(size, to: label)
        return label
    }
    func updateUIView(_ label: UILabel, context: Context) { apply(size, to: label) }
    private func apply(_ size: CGFloat, to label: UILabel) {
        label.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        label.textColor = .label
    }
}

/// Vertical pans scroll the terminal. Horizontal pans belong to the containing
/// repository pager, including when a terminal application enables mouse input.
final class PagedTerminalView: TerminalView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: self)
            let motion = velocity == .zero ? pan.translation(in: self) : velocity
            if abs(motion.x) > abs(motion.y) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

struct TerminalSurface: UIViewRepresentable {
    @ObservedObject var model: RepositoryTerminalModel
    var fontSize: CGFloat
    func makeUIView(context: Context) -> TerminalView {
        let view = model.terminalSurface()
        view.terminalDelegate = context.coordinator
        view.isDirectionalLockEnabled = true
        view.nativeBackgroundColor = .secondarySystemGroupedBackground
        view.nativeForegroundColor = .label
        // The scroll view otherwise adopts the page safe area and draws the
        // first row below the filled background.
        view.contentInsetAdjustmentBehavior = .never
        view.contentInset = .zero
        view.scrollIndicatorInsets = .zero
        view.automaticallyAdjustsScrollIndicatorInsets = false
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.backgroundColor = UIColor.secondarySystemGroupedBackground.cgColor
        view.accessibilityIdentifier = "terminal.surface"
        model.surface = view
        return view
    }
    func updateUIView(_ view: TerminalView, context: Context) {
        let next = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if abs(view.font.pointSize - next.pointSize) > 0.1 { view.font = next }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    @MainActor final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let model: RepositoryTerminalModel
        init(_ model: RepositoryTerminalModel) { self.model = model }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { model.resize(rows: newRows, cols: newCols) }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { model.send(data) }
        func setTerminalTitle(source: TerminalView, title: String) { /* untrusted title is not used as UI or a path */ }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy(source: TerminalView, content: Data) { /* OSC 52 cannot change the host clipboard */ }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
