import SwiftUI

@main
struct BookScanApp: App {
    @State private var store = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.saveNow()
            }
        }
    }
}
