import SwiftUI

@main
struct Fit3LinkApp: App {
    @StateObject private var band = BandManager.shared
    @StateObject private var logbook = Logbook.shared

    init() {
        // Cria a conexão já no lançamento: quando o iOS reabre o app em segundo plano
        // (restauração do Bluetooth), nenhuma tela é montada.
        _ = BandManager.shared
        CallMonitor.shared.start()
        if MusicBridge.shared.authorized { MusicBridge.shared.start() }
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
