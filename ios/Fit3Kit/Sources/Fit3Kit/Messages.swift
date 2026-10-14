// Mensagens SAMessageData (acima do transporte SAP). Mesma lógica de tools/fit3/messages.py.
//
// byte 0 = formato << 7 | tipo << 6 | id   (formato 0 fixo / 1 variável; tipo 0 pedido / 1 resposta)
// formato variável: byte 1 = número de parâmetros
// parâmetro = id + valor; inteiros little-endian; string = 1 byte de tamanho + UTF-8
import Foundation

public enum SAMessage {
    public struct Header: Equatable {
        public let variable: Bool
        public let isResponse: Bool
        public let id: Int
    }

    public static func parseHeader(_ message: [UInt8]) -> Header? {
        guard let b = message.first else { return nil }
        return Header(variable: b & 0x80 != 0, isResponse: b & 0x40 != 0, id: Int(b & 0x3F))
    }

    static func byte(_ id: UInt8, _ value: Int) -> [UInt8] { [id, UInt8(truncatingIfNeeded: value)] }

    static func short(_ id: UInt8, _ value: Int) -> [UInt8] {
        [id, UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }

    static func int32(_ id: UInt8, _ value: Int32) -> [UInt8] {
        let v = UInt32(bitPattern: value)
        return [id] + (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }
    }

    static func int64(_ id: UInt8, _ value: Int64) -> [UInt8] {
        let v = UInt64(bitPattern: value)
        return [id] + (0..<8).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }
    }

    /// Trunca em no máximo `maxBytes` de UTF-8 sem cortar um caractere ao meio.
    static func utf8Prefix(_ text: String, maxBytes: Int) -> [UInt8] {
        var out: [UInt8] = []
        for ch in text {
            let encoded = Array(String(ch).utf8)
            if out.count + encoded.count > maxBytes { break }
            out += encoded
        }
        return out
    }

    static func string(_ id: UInt8, _ text: String, maxBytes: Int = 255) -> [UInt8] {
        let raw = utf8Prefix(text, maxBytes: min(maxBytes, 255))
        return [id, UInt8(raw.count)] + raw
    }

    static func millis(_ date: Date) -> Int64 {
        Int64(max(0, (date.timeIntervalSince1970 * 1000).rounded()))
    }
}

// MARK: - Serviço 1: OOBE (configuração inicial e hora)

public enum Oobe {
    public static let watchInfo: [UInt8] = [0x01, 0x04, 0x02, 0, 0, 0, 0x05, 0, 0x0E]
    public static let deviceStatus: [UInt8] = [0x02, 0x01, 0x00]
    public static let userAgreement: [UInt8] = [0x84, 0x01, 0x01]

    /// Mensagem 3: idioma, roaming, hora (epoch em ASCII), fuso, formato 24h. Também acerta a hora.
    public static func initSettings(localeId: Int, date: Date = Date(),
                                    timeZone: TimeZone = .current, hour24: Bool = true) -> [UInt8] {
        let offset = timeZone.secondsFromGMT(for: date)
        let absOffset = abs(offset)
        let epoch = Array(String(Int64(date.timeIntervalSince1970.rounded(.down))).utf8)
        var out: [UInt8] = [0x83]
        out += SAMessage.short(1, localeId)
        out += SAMessage.byte(2, 0)                               // roaming desligado
        out += [3, UInt8(epoch.count)] + epoch
        out += [4, offset < 0 ? 1 : 0, UInt8(absOffset & 0xFF), UInt8((absOffset >> 8) & 0xFF)]
        out += SAMessage.byte(5, hour24 ? 1 : 0)
        return out
    }

    /// 1...4 para as respostas 0x41...0x44.
    public static func responseId(_ message: [UInt8]) -> Int? {
        guard let h = message.first, (0x41...0x44).contains(h) else { return nil }
        return Int(h & 0x3F)
    }

    public static func firmware(in message: [UInt8]) -> String? {
        let ascii = String(decoding: message.map { $0 < 128 ? $0 : 0x2E }, as: UTF8.self)
        guard let r = ascii.range(of: "R390[A-Z0-9]{7,12}", options: .regularExpression) else { return nil }
        return String(ascii[r])
    }
}

// MARK: - Serviço 11: configurações completas (bateria, idioma)

public enum BandSettings {
    public static let batteryRequest: [UInt8] = [0x02]

    public static func language(localeId: Int) -> [UInt8] { [0x01] + SAMessage.short(4, localeId) }

    public struct Battery: Equatable {
        public let percent: Int
        public let charging: Bool
    }

    public static func parseBattery(_ m: [UInt8]) -> Battery? {
        guard let h = SAMessage.parseHeader(m), h.isResponse, h.id == 2, m.count >= 3 else { return nil }
        var level: Int?
        var charging: Int?
        var i = 1
        while i + 1 < m.count {                         // pares (id, valor) de 1 byte
            if m[i] == 5, m[i + 1] <= 100 { level = Int(m[i + 1]) }
            if m[i] == 6, m[i + 1] <= 3 { charging = Int(m[i + 1]) }
            i += 2
        }
        if level == nil || charging == nil {            // ressincroniza se houver campo de outra largura
            for p in 1..<(m.count - 1) {
                if m[p] == 5, m[p + 1] <= 100, level == nil { level = Int(m[p + 1]) }
                if m[p] == 6, m[p + 1] <= 3, charging == nil { charging = Int(m[p + 1]) }
            }
        }
        guard let l = level, let c = charging else { return nil }
        return Battery(percent: l, charging: c != 0)
    }
}

// MARK: - Serviço 7: notificações

public enum BandNotification {
    public static let iconCapabilityRequest: [UInt8] = [0x0D]

    public static func isIconCapability(_ m: [UInt8]) -> Bool {
        SAMessage.parseHeader(m)?.id == 13
    }

    public static func new(sequence: Int32, title: String, body: String, appName: String,
                           package: String, appId: Int, date: Date = Date(),
                           popup: Bool = true, category: String? = nil) -> [UInt8] {
        precondition(sequence > 0)
        let bodyRaw = SAMessage.utf8Prefix(body, maxBytes: 100)
        var params: [[UInt8]] = [
            SAMessage.byte(0, 1),                                    // tipo: normal
            SAMessage.int32(1, sequence),
            SAMessage.string(6, String(appId)),
            SAMessage.int64(2, SAMessage.millis(date)),
            SAMessage.string(3, title, maxBytes: 60),
            [4, UInt8(bodyRaw.count & 0xFF), UInt8(bodyRaw.count >> 8)] + bodyRaw,  // tamanho de 2 bytes
            SAMessage.string(14, appName, maxBytes: 60),
            SAMessage.byte(15, 1),
            SAMessage.byte(16, 0),
        ]
        if let category, !category.isEmpty { params.append(SAMessage.string(12, category, maxBytes: 60)) }
        params.append(SAMessage.string(18, package, maxBytes: 60))
        return [popup ? 0x80 : 0x85, UInt8(params.count)] + params.flatMap { $0 }
    }

    public static func delete(sequence: Int32) -> [UInt8] { [0x01] + SAMessage.int32(1, sequence) }
    public static let clearAll: [UInt8] = [0x08]

    /// Confirmação da pulseira: 40 01 <seq LE32> 0b <1 = aceita>.
    public static func parseAck(_ m: [UInt8]) -> (sequence: Int32, accepted: Bool)? {
        guard m.count == 8, m[0] == 0x40, m[1] == 1, m[6] == 11 else { return nil }
        let raw = (0..<4).reduce(UInt32(0)) { $0 | UInt32(m[2 + $1]) << ($1 * 8) }
        return (Int32(bitPattern: raw), m[7] == 1)
    }
}

/// "Apps" que o iPhone encaminha. IDs >= 20 ficam na faixa que a Samsung usa para apps do wearable.
public enum ForwardedApp: String, CaseIterable {
    case test, phone, messages, mail, other

    public var appId: Int {
        switch self {
        case .test: return 20
        case .phone: return 21
        case .messages: return 22
        case .mail: return 23
        case .other: return 24
        }
    }

    public var displayName: String {
        switch self {
        case .test: return "Fit3 Link"
        case .phone: return "Telefone"
        case .messages: return "Mensagens"
        case .mail: return "E-mail"
        case .other: return "iPhone"
        }
    }

    /// Pacotes Android cujo ícone/comportamento o firmware pode já conhecer.
    public var package: String {
        switch self {
        case .test: return "dev.fit3link.app"
        case .phone: return "com.samsung.android.dialer"
        case .messages: return "com.samsung.android.messaging"
        case .mail: return "com.google.android.gm"
        case .other: return "dev.fit3link.other"
        }
    }

    /// Notification.CATEGORY_* do Android.
    public var category: String? {
        switch self {
        case .phone: return "call"
        case .messages: return "msg"
        case .mail: return "email"
        default: return nil
        }
    }
}

// MARK: - Serviço 3: chamadas (CallPacketConstructor do plugin oficial)

public enum BandCall {
    public enum State: UInt8 { case idle = 0, ringing = 1, offhook = 2 }

    public enum BandAction: Equatable {
        case silence, showOnPhone, reject, missedSync, callBack, rejectWithMessage, clearMissed
        case unknown(Int)
    }

    static let agentName = "com.samsung.android.providers.sacall.SACallHandlerService"

    public static func enableNotification(_ on: Bool = true) -> [UInt8] { [0x08, on ? 1 : 0] }
    public static func state(_ s: State) -> [UInt8] { [0x03, s.rawValue] }
    public static let deleteMissedCalls: [UInt8] = [0x07]

    public static func contact(name: String, number: String, date: Date = Date(),
                               video: Bool = false, dndException: Bool = false) -> [UInt8] {
        let shownName = name == number ? "" : name
        var out: [UInt8] = [0x82, 7]
        out += SAMessage.byte(0, video ? 0 : 1)
        out += SAMessage.int32(7, 1)
        out += SAMessage.string(5, agentName)
        out += SAMessage.int64(6, SAMessage.millis(date))
        out += SAMessage.string(4, shownName, maxBytes: 127)
        out += SAMessage.string(3, number, maxBytes: 127)
        out += SAMessage.byte(9, dndException ? 1 : 0)
        return out
    }

    public static func missed(name: String, number: String, date: Date = Date(), alert: Bool = true) -> [UInt8] {
        let shownName = name == number ? "" : name
        var out: [UInt8] = [alert ? 0x86 : 0x8A, 3]
        out += SAMessage.string(4, shownName, maxBytes: 127)
        out += SAMessage.string(3, number, maxBytes: 127)
        out += SAMessage.int64(6, SAMessage.millis(date))
        return out
    }

    public static func parseBandAction(_ m: [UInt8]) -> BandAction? {
        guard let h = SAMessage.parseHeader(m), !h.isResponse else { return nil }
        switch h.id {
        case 1: return .silence
        case 4: return .showOnPhone
        case 5: return .reject
        case 9: return .missedSync
        case 13: return .callBack
        case 14: return .rejectWithMessage
        case 15: return .clearMissed
        default: return .unknown(h.id)
        }
    }
}

// MARK: - IDs de idioma da pulseira (LocaleUtils do plugin oficial)

public enum BandLocale {
    public static let ids: [String: Int] = [
        "ar": 0, "az-AZ": 2, "bg": 4, "bs": 7, "ca": 8, "cs": 9, "da": 10, "de": 11, "el": 12,
        "en": 13, "en-US": 100, "en-CA": 77, "en-PH": 78, "es-ES": 14, "es-US": 83, "es-MX": 83,
        "fi": 18, "fr": 20, "fr-CA": 84, "hi": 24, "hr": 25, "hu": 26, "id": 28, "it": 30,
        "he": 31, "ja": 32, "ko": 37, "lt": 40, "lv": 41, "nb": 49, "nl": 51, "pl": 54,
        "pt-BR": 82, "pt-PT": 55, "ro": 56, "ru": 57, "sk": 59, "sl": 60, "sr": 62, "sv": 63,
        "th": 68, "tr": 69, "uk": 71, "vi": 73, "zh-CN": 96, "zh-HK": 80, "zh-TW": 81,
    ]

    /// Melhor correspondência para uma tag como "pt-BR", "pt_BR" ou "en-GB". Padrão: inglês.
    public static func id(forLanguageTag tag: String) -> Int {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let lang = parts.first?.lowercased() else { return 13 }
        if parts.count > 1, let id = ids["\(lang)-\(parts[parts.count - 1].uppercased())"] { return id }
        if let id = ids[lang] { return id }
        if let key = ids.keys.sorted().first(where: { $0.hasPrefix(lang + "-") }), let id = ids[key] { return id }
        return 13
    }

    /// Idioma atual do iPhone.
    public static var current: Int {
        id(forLanguageTag: Locale.preferredLanguages.first ?? "pt-BR")
    }
}
