import CallKit
import Foundation

/// Observa chamadas (telefone e VoIP como WhatsApp) e faz a pulseira tocar pelo agente de
/// chamadas da Samsung, como o plugin oficial do Android.
/// O iOS não informa a apps quem está ligando, então a pulseira mostra um texto genérico.
/// Só funciona com o app em execução — veja `KeepAlive` para segundo plano.
final class CallMonitor: NSObject, CXCallObserverDelegate {
    static let shared = CallMonitor()

    private let observer = CXCallObserver()
    private var activeCall: UUID?
    private var answered = false

    private var enabled: Bool { UserDefaults.standard.object(forKey: "calls.enabled") as? Bool ?? true }
    private var notifyMissed: Bool { UserDefaults.standard.object(forKey: "calls.missed") as? Bool ?? true }

    func start() {
        observer.setDelegate(self, queue: .main)
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let band = BandManager.shared
        let incomingRinging = !call.isOutgoing && !call.hasConnected && !call.hasEnded

        if incomingRinging {
            guard enabled, activeCall == nil else { return }
            activeCall = call.uuid
            answered = false
            Logbook.shared.add("Chamada recebida no iPhone")
            band.startRinging(name: "Chamada no iPhone", number: "")
            return
        }

        guard call.uuid == activeCall else { return }
        if call.hasEnded {
            activeCall = nil
            Logbook.shared.add(answered ? "Chamada encerrada" : "Chamada perdida")
            band.callEnded(missed: !answered && notifyMissed, name: "Chamada perdida", number: "")
        } else if call.hasConnected && !answered {
            answered = true
            band.callAnswered()
        }
    }
}
