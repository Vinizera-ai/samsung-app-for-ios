// Serviço 10: saúde. O celular se apresenta como Samsung Health e a pulseira envia os dados.
// Mesma lógica de tools/fit3/health.py — veja os comentários de lá e docs/PROTOCOLO.md.
import Foundation

public enum BandHealth {
    /// A pulseira conta segundos a partir de 1990-01-01 UTC.
    public static let epoch1990: Int64 = 631_152_000

    static let seqId: UInt8 = 0xE0
    static let protoId: UInt8 = 0xE1
    static let emulatedSHealthVersion: Int32 = 7_006_011
    static let fit3MinSHealthVersion: Int32 = 6_040_000

    public static let dataSteps = 7
    public static let dataHeartRate = 10
    public static let dataSleep = 16
    public static let dataSleepStage = 17
    public static let dataStress = 19
    public static let dataSpO2 = 112

    public static let sleepAwake = 40001
    public static let sleepLight = 40002
    public static let sleepDeep = 40003
    public static let sleepREM = 40004

    /// Pedido de capacidade do host (o plugin oficial manda este byte para começar).
    public static let mobileCapabilityRequest: [UInt8] = [0x34]

    public enum Event: Equatable {
        case gmCapability, wearableCapability, capability, checkStatus, syncData, requestData, wearableMessage
        case other(Int)
        case invalid
    }

    // MARK: Bytes

    static func u16(_ b: [UInt8], _ o: Int) -> Int? {
        o >= 0 && o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : nil
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[o + $1]) << ($1 * 8) }
    }

    static func i32(_ b: [UInt8], _ o: Int) -> Int { Int(Int32(bitPattern: u32(b, o))) }

    static func le16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }

    static func le32(_ v: Int64) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }

    /// Tempo da pulseira (u32 LE) -> Date.
    public static func bandTime(_ b: [UInt8], _ o: Int = 0) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int64(u32(b, o)) + epoch1990))
    }

    public static func sequence(_ m: [UInt8]) -> Int? {
        guard let h = SAMessage.parseHeader(m) else { return nil }
        let off = h.id == 7 ? 1 : (h.id == 2 || h.variable ? 2 : 1)
        guard m.count > off, m[off] == seqId else { return nil }
        return u16(m, off + 1)
    }

    // MARK: Pedidos e respostas

    /// REQUEST_DATA com o DeviceInfo de 25 bytes do plugin (cursor zero = troca completa).
    public static func requestData(sequence: Int, now: Date = Date()) -> [UInt8] {
        let end = min(max(Int64(now.timeIntervalSince1970) - epoch1990, 0), Int64(UInt32.max))
        var out: [UInt8] = [3, seqId]
        out.append(contentsOf: le16(sequence))
        out.append(contentsOf: [5, 25, 1, 0, 2, 0, 0, 3, 4, 51] as [UInt8])
        out.append(4)
        out.append(contentsOf: le32(0))
        out.append(5)
        out.append(contentsOf: le32(0))
        out.append(6)
        out.append(contentsOf: le32(end))
        out.append(contentsOf: [7, 1] as [UInt8])
        return out
    }

    static func parseGMRequest(_ m: [UInt8]) -> (sequence: Int, proto: Int)? {
        guard let h = SAMessage.parseHeader(m), h.id == 34, h.variable, m.count >= 2 else { return nil }
        var seq: Int?
        var proto: Int?
        var i = 2
        for _ in 0..<Int(m[1]) {
            guard i < m.count else { break }
            let pid = m[i]
            i += 1
            if pid == seqId || pid == protoId {
                let value = u16(m, i)
                i += 2
                if pid == seqId { seq = value } else { proto = value }
            } else if pid == 0xD0 || pid == 0xD1 {
                i += 1
            } else if pid == 0xD2 || pid == 0xD3 {
                i += 4
            } else {
                break // largura desconhecida
            }
        }
        guard let s = seq, let p = proto else { return nil }
        return (s, p)
    }

    static func gmCapabilityResponse(sequence: Int, proto: Int) -> [UInt8] {
        var out: [UInt8] = [0xE2, 6, 0xD0, 2, 0xD1, 0]
        out.append(0xD2)
        out.append(contentsOf: le32(Int64(emulatedSHealthVersion)))
        out.append(0xD3)
        out.append(contentsOf: le32(Int64(fit3MinSHealthVersion)))
        out.append(seqId)
        out.append(contentsOf: le16(sequence))
        out.append(protoId)
        out.append(contentsOf: le16(proto))
        return out
    }

    static func capabilitySequence(_ m: [UInt8]) -> Int? {
        if m.count >= 5, m[2] == seqId { return u16(m, 3) }
        guard m.count > 4 else { return nil }
        for i in 2..<(m.count - 2) where m[i] == seqId { return u16(m, i + 1) }
        return nil
    }

    static let capabilityStrings: [(UInt8, String)] = [
        (0xC0, "com.samsung.android.app.shealth.RESPONSE_CAPABILITY"),
        (0xC1, "shealth"),
        (0xC2, "wearable"),
        (0xAE, #"{"pedometer":4}"#),
        (0xAF, #"{"wearable_messaging":true,"compression":true,"wm_chunk_size":10000,"sync_duration":30,"blob_compression":true}"#),
        (0xB1, #"{"common_sync":"com.samsung.android.app.shealth.wearable.syncmanager"}"#),
        (0xB3, #"{"pedometer_sync":{"support_wearable_all_step":true},"goal_support":{"pedometer":1,"floor":1,"water":0},"daily_activity":{"support":false},"dashboard_config_sync":{"version":1000,"is_support":true}}"#),
        (0xAC, #"{"os":"android","os_version":"16","country_iso":"","one_ui_version":-1}"#),
        (0xC3, #"{"message_version":5.18,"message_support":true,"message_compression":true,"message_compression_format":"gzip","message_size":10000}"#),
        (0xAD, #"{"support":false,"target_list":"settings.band.manage_exercises"}"#),
    ]

    /// Capacidade do Samsung Health 7.0.6 (protocolo 4.51), como o plugin oficial gera.
    static func wearableCapabilityResponse(sequence: Int) -> [UInt8] {
        var params: [[UInt8]] = [
            [seqId] + le16(sequence),
            [0xA1, 4, 0x51],
            [0xA2] + le32(Int64(emulatedSHealthVersion)),
        ]
        for (pid, text) in capabilityStrings {
            let raw = Array(text.utf8)
            params.append([pid, UInt8(raw.count)] + raw)
        }
        return [0xE0, UInt8(params.count)] + params.flatMap { $0 }
    }

    static let success: [UInt8] = [0x04, 0x02, 0x01, 0x01]

    static func syncDataSuccess(_ m: [UInt8]) -> [UInt8]? {
        guard m.count >= 5, m[2] == seqId else { return nil }
        return [0x42, 0x02, seqId, m[3], m[4]] + success
    }

    static func requestDataSuccess(_ m: [UInt8]) -> [UInt8]? {
        guard m.count >= 4, m[1] == seqId else { return nil }
        return [0x43, seqId, m[2], m[3]] + success
    }

    /// Classifica uma mensagem da pulseira e devolve a resposta a enviar.
    public static func reply(for m: [UInt8]) -> (event: Event, reply: [UInt8]?) {
        guard let h = SAMessage.parseHeader(m) else { return (.invalid, nil) }
        let request = !h.isResponse
        switch h.id {
        case 34:
            if request, let gm = parseGMRequest(m) {
                return (.gmCapability, gmCapabilityResponse(sequence: gm.sequence, proto: gm.proto))
            }
            return (.capability, nil)
        case 32:
            if request, let seq = capabilitySequence(m) {
                return (.wearableCapability, wearableCapabilityResponse(sequence: seq))
            }
            return (.capability, nil)
        case 33, 35, 52:
            return (.capability, nil)
        case 1:
            return (.checkStatus, request ? [0x41] : nil)
        case 2:
            return (.syncData, request ? syncDataSuccess(m) : nil)
        case 3:
            return (.requestData, request ? requestDataSuccess(m) : nil)
        case 4:
            return (.wearableMessage, request ? [0x44] : nil)
        default:
            return (.other(h.id), nil)
        }
    }

    // MARK: Dados

    public struct StepBin: Codable, Equatable {
        public let start: Date
        public let end: Date
        public let count: Int
        public let walk: Int
        public let run: Int
        public let distanceMeters: Double
        public let calories: Double
        public let durationMs: Int
    }

    public struct Vital: Equatable {
        public let type: Int
        public let start: Date?
        public let end: Date?
        public let value: Int?
        public let min: Int?
        public let max: Int?
        public let score: Int?
        public let uuid: String?
        public var measuredAt: Date? { end ?? start }
    }

    public struct SleepStage: Codable, Equatable, Hashable {
        public let sleepId: String
        public let start: Date
        public let end: Date
        public let kind: Int

        public init(sleepId: String, start: Date, end: Date, kind: Int) {
            self.sleepId = sleepId
            self.start = start
            self.end = end
            self.kind = kind
        }
    }

    static func isSync(_ m: [UInt8], type: Int) -> Bool {
        m.count >= 6 && m[0] == 0x82 && m[2] == seqId && Int(m[5]) == type
    }

    /// Tipo 7: byte "tem mais" + 12 campos fixos por intervalo de 1 minuto.
    public static func parseStepBins(_ m: [UInt8]) -> [StepBin]? {
        guard m.count >= 8, isSync(m, type: dataSteps) else { return nil }
        var out: [StepBin] = []
        var i = 6
        for _ in 0..<128 {
            if i >= m.count { return out.isEmpty ? nil : out }
            let more = m[i]
            i += 1
            guard more <= 1 else { return nil }
            var v: [UInt8: Int] = [:]   // id -> posição do valor
            for fid: UInt8 in [5, 1, 2, 3, 16, 17, 18, 19, 20, 21, 22, 23] {
                let width = fid == 23 ? 1 : 4
                guard i < m.count, m[i] == fid, i + 1 + width <= m.count else { return nil }
                v[fid] = i + 1
                i += 1 + width
            }
            let start = bandTime(m, v[1]!)
            var end = bandTime(m, v[2]!)
            let count = i32(m, v[16]!)
            let distance = Double(Float(bitPattern: u32(m, v[17]!)))
            let calories = Double(Float(bitPattern: u32(m, v[19]!)))
            let run = i32(m, v[20]!), walk = i32(m, v[21]!), duration = i32(m, v[22]!)
            guard (0...100_000).contains(count), (0...count).contains(walk), (0...count).contains(run),
                  distance.isFinite, (0.0...100_000.0).contains(distance),
                  calories.isFinite, (0.0...10_000.0).contains(calories),
                  (0...86_400_000).contains(duration) else { return nil }
            if !(end > start && end <= start.addingTimeInterval(3600)) { end = start.addingTimeInterval(60) }
            out.append(StepBin(start: start, end: end, count: count, walk: walk, run: run,
                               distanceMeters: distance, calories: calories, durationMs: duration))
            if more == 0 { return out }
        }
        return nil
    }

    /// >0 largura fixa, -1 blob com tamanho de 4 bytes, 0 desconhecido (rejeita o pacote).
    static func fieldWidth(type: Int, id: UInt8) -> Int {
        if [1, 2, 3, 5, 151, 153].contains(id) { return 4 }
        switch type {
        case dataHeartRate:
            switch id { case 32, 33, 34, 35: return 1; case 36: return -1; case 37: return 2; default: return 0 }
        case dataStress:
            switch id { case 96, 102, 103: return 1; case 97: return 4; case 98: return -1; default: return 0 }
        case dataSpO2:
            switch id {
            case 117: return 16
            case 169, 170, 171, 172: return 1
            case 173: return 2
            case 174: return 4
            case 175: return -1
            default: return 0
            }
        case dataSleep:
            switch id {
            case 28...37: return 2
            case 40, 80: return 4
            case 81, 83, 86: return 1
            case 82, 117: return 16
            default: return 0
            }
        default:
            return 0
        }
    }

    /// Tipos 10 (FC), 16 (sono), 19 (estresse), 112 (SpO2): registros com tamanho de 4 bytes.
    public static func parseVitals(_ m: [UInt8]) -> [Vital]? {
        guard m.count >= 12, m[0] == 0x82, m[2] == seqId else { return nil }
        let type = Int(m[5])
        guard [dataHeartRate, dataSleep, dataStress, dataSpO2].contains(type) else { return nil }
        var off = 6
        var out: [Vital] = []
        for _ in 0..<128 {
            guard off + 5 <= m.count else { return nil }
            let more = m[off]
            off += 1
            guard more <= 1 else { return nil }
            let length = i32(m, off)
            off += 4
            guard length > 0, length <= 65_536, off + length <= m.count else { return nil }
            var fields: [UInt8: Int] = [:]   // id -> posição
            var p = off
            let end = off + length
            while p < end {
                let fid = m[p]
                p += 1
                let width = fieldWidth(type: type, id: fid)
                if width == 0 { return nil }
                if width < 0 {
                    guard p + 4 <= end else { return nil }
                    let blob = i32(m, p)
                    p += 4
                    guard blob >= 0, blob <= 65_536, p + blob <= end else { return nil }
                    p += blob
                } else {
                    guard p + width <= end else { return nil }
                    fields[fid] = p
                    p += width
                }
            }
            let ids: (UInt8, UInt8, UInt8)? = type == dataHeartRate ? (32, 33, 34)
                : type == dataStress ? (96, 102, 103) : type == dataSpO2 ? (169, 171, 172) : nil
            func byte(_ fid: UInt8?) -> Int? { fid.flatMap { fields[$0] }.map { Int(m[$0]) } }
            out.append(Vital(
                type: type,
                start: fields[1].map { bandTime(m, $0) },
                end: fields[2].map { bandTime(m, $0) },
                value: byte(ids?.0), min: byte(ids?.1), max: byte(ids?.2),
                score: type == dataSleep ? byte(83) : nil,
                uuid: fields[117].map { Array(m[$0..<($0 + 16)]).hex }))
            off = end
            if more == 0 { return out }
        }
        return nil
    }

    /// Tipo 17: oito campos fixos por estágio, sem tamanho prefixado.
    public static func parseSleepStages(_ m: [UInt8]) -> [SleepStage]? {
        guard m.count >= 6, isSync(m, type: dataSleepStage) else { return nil }
        var off = 6
        var out: [SleepStage] = []
        for _ in 0..<10_000 {
            guard off < m.count else { return nil }
            let more = m[off]
            off += 1
            guard more <= 1 else { return nil }
            var fields: [UInt8: Int] = [:]
            for _ in 0..<8 {
                guard off < m.count else { return nil }
                let fid = m[off]
                off += 1
                let width: Int
                switch fid {
                case 1, 2, 3, 5, 82, 151, 153: width = 4
                case 85: width = 16
                default: return nil
                }
                guard fields[fid] == nil, off + width <= m.count else { return nil }
                fields[fid] = off
                off += width
            }
            guard let s = fields[1], let e = fields[2], let k = fields[82], let id = fields[85] else { return nil }
            out.append(SleepStage(sleepId: Array(m[id..<(id + 16)]).hex, start: bandTime(m, s),
                                  end: bandTime(m, e), kind: i32(m, k)))
            if more == 0 { return out }
        }
        return nil
    }
}

/// Remonta os blocos grandes (id 63) e gera a confirmação 3E (09 aceito / 08 recusado).
public final class LargeDataReceiver {
    static let maxChunks = 256
    static let maxBytes = 1024 * 1024
    private var data: [UInt8] = []
    private var next = 0

    public init() {}

    public func reset() {
        data = []
        next = 0
    }

    static func ack(_ count: Int, accepted: Bool) -> [UInt8] {
        let status: UInt8 = accepted ? 0x09 : 0x08
        var out: [UInt8] = [62, status]
        out.append(contentsOf: BandHealth.le32(Int64(count)))
        return out
    }

    /// nil se não for bloco; senão (payload completo ou nil, confirmação ou nil).
    public func accept(_ m: [UInt8]) -> (payload: [UInt8]?, ack: [UInt8]?)? {
        guard let first = m.first, first & 0x3F == 63 else { return nil }
        guard m.count >= 6 else {
            reset()
            return (nil, Self.ack(0, accepted: false))
        }
        let flag = Int(m[1] & 0x03)
        let number = Int(BandHealth.u32(m, 2))
        if flag == 0 && number == 0 { reset() }
        guard flag <= 2, (flag == 0) == (number == 0), number == next, next < Self.maxChunks,
              data.count + m.count - 6 <= Self.maxBytes else {
            reset()
            return (nil, Self.ack(number, accepted: false))
        }
        data += m[6...]
        next += 1
        guard flag == 2 else { return (nil, nil) }
        let payload = data
        let count = next
        reset()
        return (payload, Self.ack(count, accepted: true))
    }
}
