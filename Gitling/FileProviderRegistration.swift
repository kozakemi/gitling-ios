import FileProvider
import Foundation

enum FileProviderRegistration {
    static let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier("repositories"),
        displayName: "Gitling"
    )

    static func register(report: ((String?) -> Void)? = nil) {
        NSFileProviderManager.add(domain) { error in
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
    }
}
