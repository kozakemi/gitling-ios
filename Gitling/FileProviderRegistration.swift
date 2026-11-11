import FileProvider
import Foundation

enum FileProviderRegistration {
    static let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier("repositories"),
        displayName: "Gitling"
    )

    static var usesProviderLocation: Bool {
        // Standard Xcode simulator signing supplies the App Group entitlement.
        // Use our provider rather than the simulator's broken app-container source.
        RepoStorage.groupContainer != nil
    }

    static func register(report: ((String?) -> Void)? = nil) {
#if targetEnvironment(simulator)
        do {
            guard let group = RepoStorage.groupContainer else { throw CocoaError(.fileReadNoPermission) }
            try ProviderWorkspace.publish(repositories: RepoStorage.repositoriesRoot(), metadata: RepoStorage.storageBase(), sharedGroup: group)
        } catch {
            report?(String(format: String(localized: "The Files location could not be added: %@"), error.localizedDescription))
            return
        }
#endif
        NSFileProviderManager.add(domain) { error in
            if error == nil { signal() }
            let message = error.map { error in
                String(
                    format: String(localized: "The Files location could not be added: %@"),
                    error.localizedDescription
                )
            }
            report?(message)
        }
    }

    static func signal(_ identifier: NSFileProviderItemIdentifier = .rootContainer) {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: identifier) { _ in }
        // Replicated providers also need an indexed change notification when no
        // folder enumerator is active (for example, while the app is foreground).
        if identifier != .workingSet { manager.signalEnumerator(for: .workingSet) { _ in } }
    }
}
