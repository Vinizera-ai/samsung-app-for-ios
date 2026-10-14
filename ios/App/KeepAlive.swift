import AVFoundation
import Foundation

/// Opcional: toca silêncio em loop para o iOS não suspender o app, assim o `CallMonitor`
/// continua recebendo eventos de chamada em segundo plano. Gasta um pouco mais de bateria.
final class KeepAlive {
    static let shared = KeepAlive()

    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "keepAlive.enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "keepAlive.enabled")
            if newValue { start() } else { stop() }
        }
    }

    func startIfEnabled() {
        if enabled { start() }
    }

    private func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                let p = try AVAudioPlayer(data: Self.silentWav())
                p.numberOfLoops = -1
                p.volume = 0
                player = p
            }
            player?.play()
            observeInterruptions()
            Logbook.shared.add("Modo segundo plano ativo")
        } catch {
            Logbook.shared.add("Falha no modo segundo plano: \(error.localizedDescription)")
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Logbook.shared.add("Modo segundo plano desligado")
    }

    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.enabled,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.startIfEnabled() }
        }
    }

    /// 1 s de silêncio: WAV PCM 16 bits, mono, 8 kHz.
    private static func silentWav() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + dataSize); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        text("data"); u32(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
