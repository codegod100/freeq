import SwiftUI
import WatchConnectivity

@main
struct FreeqWatchApp: App {
    @StateObject private var watch = WatchSession()

    var body: some Scene {
        WindowGroup {
            BufferListView()
                .environmentObject(watch)
                .onAppear { watch.activate() }
        }
    }
}
