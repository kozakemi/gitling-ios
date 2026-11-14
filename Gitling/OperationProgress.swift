import Foundation

typealias GitProgressHandler = @Sendable (GitProgress) -> Void

struct GitProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case preparing, connecting, authenticating, receiving, indexing, resolving, packing, sending
        case checkingOut, merging, largeFiles, checkingSubmodules, configuringSubmodule, refreshing, waitingForRemote

        func title(locale: Locale = .current) -> String {
            switch self {
            case .preparing: String(localized: "Preparing operation…", locale: locale)
            case .connecting: String(localized: "Connecting to remote…", locale: locale)
            case .authenticating: String(localized: "Authenticating…", locale: locale)
            case .receiving: String(localized: "Receiving objects…", locale: locale)
            case .indexing: String(localized: "Indexing objects…", locale: locale)
            case .resolving: String(localized: "Resolving deltas…", locale: locale)
            case .packing: String(localized: "Preparing objects to send…", locale: locale)
            case .sending: String(localized: "Sending objects…", locale: locale)
            case .checkingOut: String(localized: "Checking out files…", locale: locale)
            case .merging: String(localized: "Merging commits…", locale: locale)
            case .largeFiles: String(localized: "Processing Git LFS files…", locale: locale)
            case .checkingSubmodules: String(localized: "Checking submodules and local changes…", locale: locale)
            case .configuringSubmodule: String(localized: "Configuring submodule…", locale: locale)
            case .refreshing: String(localized: "Refreshing repository status…", locale: locale)
            case .waitingForRemote: String(localized: "Waiting for remote confirmation…", locale: locale)
            }
        }
    }

    var phase: Phase
    var completed: Int = 0
    var total: Int = 0
    var bytes: Int = 0
    var byteTotal: Int = 0
    var submodule: String? = nil

    /// Each phase has its own denominator; there is no invented overall percent.
    var fraction: Double? {
        if phase == .largeFiles, byteTotal > 0 { return min(1, max(0, Double(bytes) / Double(byteTotal))) }
        return total > 0 ? min(1, max(0, Double(completed) / Double(total))) : nil
    }
    func countText(locale: Locale = .current) -> String? {
        guard total > 0 else { return nil }
        let format = phase == .checkingOut ? String(localized: "%lld of %lld files", locale: locale) :
            phase == .resolving ? String(localized: "%lld of %lld deltas", locale: locale) : String(localized: "%lld of %lld objects", locale: locale)
        return String(format: format, min(max(0, completed), total), total)
    }
}

/// Scoped copies share the same sink; no remote output, URLs or file contents
/// enter progress messages. Callbacks remain synchronous and cannot change Git results.
struct GitProgressReporter: Sendable {
    let handler: GitProgressHandler?
    var submodule: String? = nil
    func report(_ phase: GitProgress.Phase, completed: Int = 0, total: Int = 0, bytes: Int = 0, byteTotal: Int = 0) {
        handler?(.init(phase: phase, completed: completed, total: total, bytes: bytes, byteTotal: byteTotal, submodule: submodule))
    }
    func scoped(to path: String) -> Self { .init(handler: handler, submodule: path) }
}

struct OperationProgressState: Identifiable, Sendable {
    let id: UUID
    let title: String
    let repository: String?
    let startedAt: Date
    var progress: GitProgress
}

/// One pending delivery regardless of callback count. The last snapshot wins;
/// high-volume object/checkout callbacks never enqueue one UI task per object.
final class GitProgressRelay: @unchecked Sendable {
    typealias Schedule = @Sendable (@escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private let schedule: Schedule
    private let deliver: GitProgressHandler
    private var latest: GitProgress?
    private var pending = false
    private var closed = false

    init(schedule: @escaping Schedule = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }, deliver: @escaping GitProgressHandler) {
        self.schedule = schedule; self.deliver = deliver
    }

    func submit(_ value: GitProgress) {
        let enqueue = lock.withLock {
            guard !closed else { return false }
            latest = value
            guard !pending else { return false }
            pending = true
            return true
        }
        if enqueue { schedule { [weak self] in self?.drain() } }
    }

    func invalidate() {
        lock.withLock { closed = true; latest = nil }
    }

    private func drain() {
        let value = lock.withLock { () -> GitProgress? in
            pending = false
            guard !closed else { return nil }
            let value = latest; latest = nil
            return value
        }
        if let value { deliver(value) }
    }
}
