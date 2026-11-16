import SwiftUI

@main
struct GitlingApp: App {
    @StateObject private var store = RepoStore()

    init() { UserDefaults.standard.set(false, forKey: TerminalEnvironmentStore.pendingKey) }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--terminal-reset-qa") { TerminalResetQAView() }
            else { regularContent }
            #else
            regularContent
            #endif
        }
    }
    @ViewBuilder private var regularContent: some View {
            #if ISH_PROTOTYPE
            if ProcessInfo.processInfo.arguments.contains("--ish-prototype") {
                IshPrototypeView()
            } else {
                RepoListView().environmentObject(store)
            }
            #else
            RepoListView()
                .environmentObject(store)
            #endif
    }

}
