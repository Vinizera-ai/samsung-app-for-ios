import SwiftUI

@main
struct Fit3LinkApp: App {
    @StateObject private var band = BandManager.shared
    @StateObject private var logbook = Logbook.shared

    init() {
        CallMonitor.shared.start()
        KeepAlive.shared.startIfEnabled()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(band)
                .environmentObject(logbook)
        }
    }
}
