// Serviço 9: música. IDs de com.samsung.wearable.providers.samusic.message.SMediaMessageContracts.
// Mesma lógica de tools/fit3/messages.py (classe Media).
import Foundation

public enum BandMedia {
    /// Pedidos pulseira → celular.
    public enum Request: Int {
        case mediaChanged = 1, metadata = 2, playbackState = 3, remoteControl = 4, capability = 5
        case volumeInfo = 6, volumeControl = 7, appInfo = 8, queue = 9, skipToItem = 16
    }

    public enum Playback: UInt8 { case stopped = 1, paused = 2, playing = 3 }
    public enum RemoteAction: UInt8 { case stop = 1, playPause = 2, previous = 3, next = 4 }
    public enum VolumeAction: UInt8 { case set = 1, up = 2, down = 3, muteOn = 4, muteOff = 5 }

    public struct Remote: Equatable {
        public let action: RemoteAction
        /// Um toque gera "solto" e "pressionado": só aja no pressionado.
        public let pressed: Bool
    }

    public struct Volume: Equatable {
        public let action: VolumeAction
        public let value: Int?
    }

    public static func request(_ m: [UInt8]) -> Request? {
        guard let h = SAMessage.parseHeader(m), !h.isResponse else { return nil }
        return Request(rawValue: h.id)
    }

    public static func parseRemote(_ m: [UInt8]) -> Remote? {
        guard request(m) == .remoteControl else { return nil }
        var action: RemoteAction?
        var key: UInt8 = 2
        var i = 1
        while i + 1 < m.count {
            if m[i] == 1 { action = RemoteAction(rawValue: m[i + 1]) }
            if m[i] == 2 { key = m[i + 1] }
            i += 2
        }
        return action.map { Remote(action: $0, pressed: key == 2) }
    }

    public static func parseVolume(_ m: [UInt8]) -> Volume? {
        guard request(m) == .volumeControl, m.count >= 3, m[1] == 1,
              let action = VolumeAction(rawValue: m[2]) else { return nil }
        var value: Int?
        var i = 3
        while i + 1 < m.count {
            if m[i] == 2 {  // valor opcional: int32 LE, ou 1 byte em pacotes curtos
                if i + 5 <= m.count {
                    value = (0..<4).reduce(0) { $0 | Int(m[i + 1 + $1]) << ($1 * 8) }
                } else {
                    value = Int(m[i + 1])
                }
                break
            }
            i += 2
        }
        return Volume(action: action, value: value)
    }

    /// Tela de música da pulseira: 0 fechada, 1 visível, 2 always-on.
    public static func screenState(_ m: [UInt8]) -> UInt8? {
        guard request(m) == .mediaChanged, m.count >= 3, m[1] == 1, m[2] <= 2 else { return nil }
        return m[2]
    }

    public static func requestedAppId(_ m: [UInt8]) -> String? {
        guard let h = SAMessage.parseHeader(m), !h.isResponse else { return nil }
        let off = h.variable ? 2 : 1
        guard m.count >= off + 2, m[off] == 1 else { return nil }
        let end = off + 2 + Int(m[off + 1])
        guard end <= m.count else { return nil }
        return String(decoding: m[(off + 2)..<end], as: UTF8.self)
    }

    // As respostas "fixas" do agente 9 levam o número de parâmetros (igual ao Builder da Samsung).
    static func fixed(_ id: UInt8, _ params: [[UInt8]]) -> [UInt8] {
        [0x40 | id, UInt8(params.count)] + params.flatMap { $0 }
    }

    static func variable(_ id: UInt8, _ params: [[UInt8]]) -> [UInt8] {
        [0xC0 | id, UInt8(params.count)] + params.flatMap { $0 }
    }

    public static func capability(maxVolume: Int, warningVolume: Int) -> [UInt8] {
        fixed(20, [SAMessage.int32(1, Int32(maxVolume)), SAMessage.int32(2, Int32(warningVolume))])
    }

    public static func volumeInfo(_ volume: Int, headset: Bool) -> [UInt8] {
        fixed(21, [SAMessage.int32(1, Int32(volume)), SAMessage.byte(2, headset ? 2 : 1)])
    }

    public static func mediaChanged(screenState: UInt8) -> [UInt8] {
        fixed(23, [SAMessage.byte(1, Int(screenState))])
    }

    /// Anuncia se há um player ativo ("" = nenhum). Vem antes dos metadados, senão a pulseira ignora a faixa.
    public static func appCount(appId: String) -> [UInt8] {
        variable(24, [SAMessage.byte(1, appId.isEmpty ? 0 : 1), SAMessage.string(2, appId)])
    }

    public static func metadata(title: String, artist: String, durationMs: Int64, appId: String,
                                artwork: String = "") -> [UInt8] {
        variable(17, [
            SAMessage.int64(1, durationMs),
            SAMessage.string(2, title, maxBytes: 100),
            SAMessage.string(3, artist, maxBytes: 100),
            SAMessage.string(4, artwork),
            SAMessage.string(5, appId),
        ])
    }

    public static func playbackState(_ state: Playback, positionMs: Int64, appId: String,
                                     activeItemId: Int64 = -1) -> [UInt8] {
        variable(18, [
            SAMessage.byte(1, Int(state.rawValue)),
            SAMessage.int64(2, positionMs),
            SAMessage.int64(4, activeItemId),
            SAMessage.string(3, appId),
        ])
    }

    public static func appInfo(appId: String, title: String, icon: String = "") -> [UInt8] {
        variable(22, [SAMessage.string(1, appId), SAMessage.string(2, title, maxBytes: 100),
                      SAMessage.string(3, icon)])
    }

    public static func emptyQueue(appId: String, title: String) -> [UInt8] {
        variable(25, [SAMessage.string(1, appId), SAMessage.string(2, title, maxBytes: 100),
                      SAMessage.int32(3, 0), SAMessage.string(4, "")])
    }
}
