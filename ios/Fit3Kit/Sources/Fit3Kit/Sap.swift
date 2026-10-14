// Transporte SAP (Samsung Accessory Protocol) do Galaxy Fit3 sobre BLE GATT.
// Mesma lógica de tools/fit3/sap.py — veja docs/PROTOCOLO.md.
//
//   quadro  = prefixo | corpo | crc16(corpo) big-endian (CRC-16/ARC)
//   prefixo = [len, len]                    se MTU de transporte < 256
//           = [lenHi, lenLo, crc16(len)]    caso contrário
//   corpo   = [flags, seq, svc, svc, payload…]   único / primeiro fragmento
//           = [flags, seq, payload…]             continuação / último
import Foundation

public enum BandUUID {
    public static let service = "00001A1A-0000-1000-8000-00805F9B34FB"
    /// pulseira → celular (notify)
    public static let notify = "797AE4E9-2E58-4FE8-B48D-B5C79599FB9B"
    /// celular → pulseira (write)
    public static let write = "63E30BAD-4206-4596-839F-E47CBF7A4B5D"
}

/// ID de serviço SAP == "agent id" da Samsung (ConnectionConstants do plugin oficial).
public enum Agent: Int, CaseIterable {
    case oobe = 1
    case call = 3
    case location = 4
    case weather = 5
    case bandFace = 6
    case notification = 7
    case calendar = 8
    case media = 9
    case health = 10
    case fullSettings = 11
    case debug = 12
    case reminder = 14
    case widgets = 15
    case quickMessage = 18
    case quickPanel = 19
    case apps = 24
    case sharedInfo = 26
    case otaTransfer = 30

    public static func name(_ id: Int) -> String {
        Agent(rawValue: id).map { "\($0)".uppercased() } ?? "SVC\(id)"
    }
}

public struct Fit3Error: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

@inline(__always)
func ensure(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw Fit3Error(message()) }
}

public enum Sap {
    public static let capabilityLength = 105
    public static let capabilityRequest: UInt8 = 0x14
    public static let capabilityResponse: UInt8 = 0x15
    public static let maxMessage = 4096
    public static let maxFragments = 16

    // MARK: CRC-16/ARC

    public static func crc16<S: Sequence>(_ data: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    static func crcBytes<S: Sequence>(_ data: S) -> [UInt8] where S.Element == UInt8 {
        let v = crc16(data)
        return [UInt8(v >> 8), UInt8(v & 0xFF)]
    }

    // MARK: Handshake de capacidades (105 bytes, sem quadro SAP)

    public static func isCapabilityRequest(_ data: [UInt8]) -> Bool {
        data.count == capabilityLength && data[1] == capabilityRequest
    }

    /// A resposta é o mesmo pacote com o opcode trocado de 0x14 para 0x15.
    public static func capabilityReply(_ request: [UInt8]) throws -> [UInt8] {
        try ensure(request.count == capabilityLength && Int(request[0]) == capabilityLength - 1,
                   "Pedido de capacidade com tamanho inválido")
        try ensure(request[1] == capabilityRequest, "Não é um pedido de capacidade")
        var reply = request
        reply[1] = capabilityResponse
        return reply
    }

    public static func transportMtu(_ request: [UInt8]) -> Int {
        guard request.count == capabilityLength else { return 0 }
        return (Int(request[0x2C]) << 8) | Int(request[0x2D])
    }

    // MARK: Codificação

    static func encodeBody(_ body: [UInt8], mtu: Int) throws -> [UInt8] {
        let prefix: [UInt8]
        if mtu < 256 {
            try ensure(body.count <= 255, "Corpo grande demais para prefixo curto")
            prefix = [UInt8(body.count), UInt8(body.count)]
        } else {
            try ensure(body.count <= 0xFFFF, "Corpo grande demais")
            let length: [UInt8] = [UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
            prefix = length + crcBytes(length)
        }
        return prefix + body + crcBytes(body)
    }

    /// Codifica uma mensagem SAP em um ou mais quadros.
    /// - Parameters:
    ///   - mtu: MTU de transporte anunciado pela pulseira (define o layout do prefixo).
    ///   - maxFrame: maior escrita GATT possível; por padrão igual a `mtu`.
    public static func encode(service: Int, message: [UInt8], mtu: Int,
                              maxFrame: Int? = nil, stream: Int = 0) throws -> [[UInt8]] {
        try ensure((1...31).contains(service) && !message.isEmpty, "Serviço ou mensagem inválidos")
        try ensure((15...500).contains(mtu), "MTU de transporte inválido: \(mtu)")
        try ensure((0...7).contains(stream), "Stream inválido")
        let limit = min(maxFrame ?? mtu, mtu)
        let prefixSize = mtu < 256 ? 2 : 4
        let svc = UInt8(service)

        if prefixSize + 4 + message.count + 2 <= limit {
            return [try encodeBody([0, 0x40, svc, svc] + message, mtu: mtu)]
        }

        let firstCapacity = limit - prefixSize - 2 - 4
        let continueCapacity = limit - prefixSize - 2 - 2
        try ensure(firstCapacity > 0 && continueCapacity > 0, "MTU pequeno demais")

        var frames: [[UInt8]] = []
        let firstTake = min(firstCapacity, message.count)
        frames.append(try encodeBody([1 << 1, UInt8(stream << 5), svc, svc] + message[0..<firstTake], mtu: mtu))
        var offset = firstTake
        var sequence = 1
        while offset < message.count {
            try ensure(sequence < maxFragments, "Mensagem precisa de mais de 16 fragmentos")
            let take = min(continueCapacity, message.count - offset)
            let kind = offset + take >= message.count ? 3 : 2
            frames.append(try encodeBody([UInt8(kind << 1), UInt8((stream << 5) | sequence)]
                                         + message[offset..<(offset + take)], mtu: mtu))
            offset += take
            sequence += 1
        }
        return frames
    }

    // MARK: Decodificação

    public struct Fragment: Equatable {
        public let kind: Int          // 0 único, 1 primeiro, 2 continuação, 3 último
        public let sequence: Int
        public let stream: Int
        public let service: Int?
        public let payload: [UInt8]
    }

    public static func decode(_ frame: [UInt8]) throws -> Fragment {
        try ensure(frame.count >= 8, "Quadro curto demais")
        let shortOk = frame[0] == frame[1] && Int(frame[0]) + 4 == frame.count
        let longLength = (Int(frame[0]) << 8) | Int(frame[1])
        let longOk = frame.count >= 10 && longLength + 6 == frame.count
            && Array(frame[2...3]) == crcBytes(frame[0...1])
        let prefixSize: Int
        if shortOk { prefixSize = 2 } else if longOk { prefixSize = 4 } else {
            throw Fit3Error("Prefixo de quadro SAP inválido")
        }
        let body = Array(frame[prefixSize..<(frame.count - 2)])
        try ensure(Array(frame[(frame.count - 2)...]) == crcBytes(body), "CRC do quadro SAP inválido")
        try ensure(body.count >= 2, "Corpo curto demais")
        try ensure(body[0] >> 6 == 0, "Quadro de controle SAP não suportado")
        let kind = Int(body[0] >> 1) & 3
        let first = kind == 0 || kind == 1
        if first { try ensure(body.count >= 4 && body[2] == body[3], "Cabeçalho de serviço inválido") }
        return Fragment(kind: kind,
                        sequence: Int(body[1] & 0x0F),
                        stream: Int(body[1] >> 5),
                        service: first ? Int(body[2]) : nil,
                        payload: Array(body[(first ? 4 : 2)...]))
    }
}

/// Remonta uma mensagem SAP por vez; continuações fora de ordem são descartadas.
public final class SapReassembler {
    private var service: Int?
    private var stream = -1
    private var nextSequence = 0
    private var data: [UInt8] = []

    public init() {}

    public func push(_ fragment: Sap.Fragment) -> (service: Int, message: [UInt8])? {
        switch fragment.kind {
        case 0:
            reset()
            return fragment.service.map { ($0, fragment.payload) }
        case 1:
            reset()
            guard fragment.sequence == 0, let id = fragment.service else { return nil }
            service = id
            stream = fragment.stream
            nextSequence = 1
            data = fragment.payload
            return nil
        default:
            guard let id = service, fragment.stream == stream, fragment.sequence == nextSequence,
                  data.count + fragment.payload.count <= Sap.maxMessage else {
                reset()
                return nil
            }
            data += fragment.payload
            nextSequence += 1
            guard fragment.kind == 3 else { return nil }
            let result = (id, data)
            reset()
            return result
        }
    }

    public func reset() {
        service = nil
        stream = -1
        nextSequence = 0
        data = []
    }
}

public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let chars = [Character](hex.replacingOccurrences(of: " ", with: ""))
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        self = out
    }
}
