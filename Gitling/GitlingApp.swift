import SwiftUI

@main
struct GitlingApp: App {
    @StateObject private var store = RepoStore()

    var body: some Scene {
        WindowGroup {
            RepoListView()
                .environmentObject(store)
        }
    }
}
