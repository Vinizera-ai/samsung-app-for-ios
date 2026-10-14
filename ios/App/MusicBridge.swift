import AVFoundation
import Fit3Kit
import MediaPlayer
import UIKit

/// Liga a tela de música da pulseira ao Apple Music (player do sistema).
/// O iOS só deixa apps controlarem o Apple Music; Spotify e outros não têm API pública.
final class MusicBridge {
    static let shared = MusicBridge()

    static let appId = "com.apple.Music"
    static let appTitle = "Apple Music"
    /// Passos de volume anunciados à pulseira (o iPhone tem 16).
    static let maxVolume = 16

    /// Chamado quando a música ou o estado de reprodução muda.
    var onChange: (() -> Void)?

    private var started = false
    private var volumeBeforeMute = 8
    private lazy var volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))

    var enabled: Bool { UserDefaults.standard.object(forKey: "music.enabled") as? Bool ?? true }
    var authorized: Bool { MPMediaLibrary.authorizationStatus() == .authorized }

    /// Player ativo para a pulseira ("" = nenhum: a tela de música fica vazia).
    var activeAppId: String { enabled && authorized ? Self.appId : "" }

    /// Só usa o player com permissão: acessar o Apple Music sem ela é bloqueado pelo iOS.
    private var player: MPMusicPlayerController? {
        authorized ? MPMusicPlayerController.systemMusicPlayer : nil
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                if status == .authorized { self.start() }
                completion(status == .authorized)
            }
        }
    }

    func start() {
        guard !started, let player else { return }
        started = true
        player.beginGeneratingPlaybackNotifications()
        let names: [Notification.Name] = [.MPMusicPlayerControllerNowPlayingItemDidChange,
                                          .MPMusicPlayerControllerPlaybackStateDidChange]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                self?.onChange?()
            }
        }
    }

    struct Snapshot: Equatable {
        var title = ""
        var artist = ""
        var durationMs: Int64 = 0
        var positionMs: Int64 = 0
        var playback: BandMedia.Playback = .stopped

        var identity: String { "\(title)|\(artist)|\(durationMs)" }
    }

    var snapshot: Snapshot {
        guard enabled, let player else { return Snapshot() }
        let item = player.nowPlayingItem
        var s = Snapshot()
        s.title = item?.title ?? ""
        s.artist = item?.artist ?? item?.albumArtist ?? ""
        s.durationMs = Int64(max(0, (item?.playbackDuration ?? 0) * 1000))
        let position = player.currentPlaybackTime
        s.positionMs = position.isFinite ? Int64(max(0, position * 1000)) : 0
        switch player.playbackState {
        case .playing, .seekingForward, .seekingBackward: s.playback = .playing
        default: s.playback = item == nil ? .stopped : .paused
        }
        return s
    }

    @discardableResult
    func handle(_ action: BandMedia.RemoteAction) -> Bool {
        guard enabled, let player else { return false }
        switch action {
        case .playPause:
            if player.playbackState == .playing { player.pause() } else { player.play() }
        case .next: player.skipToNextItem()
        case .previous: player.skipToPreviousItem()
        case .stop: player.pause()
        }
        return true
    }

    // MARK: Volume (experimental)
    // O iOS não tem API pública para mudar o volume do sistema. Usamos o controle deslizante do
    // MPVolumeView, técnica comum que funciona com o app aberto; em segundo plano não é garantida.

    var volume: Int {
        Int((AVAudioSession.sharedInstance().outputVolume * Float(Self.maxVolume)).rounded())
    }

    var headsetConnected: Bool {
        let headsets: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { headsets.contains($0.portType) }
    }

    func handle(_ command: BandMedia.Volume) {
        let current = volume
        let target: Int
        switch command.action {
        case .up: target = current + 1
        case .down: target = current - 1
        case .set: target = command.value ?? current
        case .muteOn:
            volumeBeforeMute = max(current, 1)
            target = 0
        case .muteOff: target = volumeBeforeMute
        }
        setVolume(Float(min(max(target, 0), Self.maxVolume)) / Float(Self.maxVolume))
    }

    private func setVolume(_ value: Float) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else {
            Logbook.shared.add("Volume: controle do sistema indisponível")
            return
        }
        // O slider só aplica o valor depois de entrar no ciclo de layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            slider.value = value
        }
    }
}
