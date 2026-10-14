// Mesmos vetores de tools/tests/test_protocol.py (capturas reais + regras do plugin oficial).
import XCTest
@testable import Fit3Kit

final class ProtocolTests: XCTestCase {
    func testCrc16ArcCheckValue() {
        XCTAssertEqual(Sap.crc16(Array("123456789".utf8)), 0xBB3D)
        // Início de SAFrameworkUtils.CHECKSUM_TABLE.
        XCTAssertEqual((0..<4).map { Sap.crc16([UInt8($0)]) }, [0, 49345, 49537, 320])
    }

    func testWatchInfoFrameMatchesLiveVector() throws {
        let frames = try Sap.encode(service: Agent.oobe.rawValue, message: Oobe.watchInfo, mtu: 500)
        XCTAssertEqual(frames, [[UInt8](hex: "000dc5c10040010101040200000005000e60ea")!])
        let fragment = try Sap.decode(frames[0])
        XCTAssertEqual(fragment.service, 1)
        XCTAssertEqual(fragment.payload, Oobe.watchInfo)
    }

    func testShortPrefixBelow256() throws {
        let frame = try Sap.encode(service: 11, message: BandSettings.batteryRequest, mtu: 200)[0]
        XCTAssertEqual(Array(frame[0...1]), [5, 5])
        XCTAssertEqual(try Sap.decode(frame).payload, BandSettings.batteryRequest)
    }

    func testBadCrcRejected() throws {
        var frame = try Sap.encode(service: 6, message: [0x02], mtu: 500)[0]
        frame[frame.count - 1] ^= 1
        XCTAssertThrowsError(try Sap.decode(frame))
    }

    func testFragmentationRoundTrip() throws {
        let message = (0..<1024).map { UInt8($0 & 0xFF) }
        let cases: [(mtu: Int, maxFrame: Int?)] = [(500, nil), (500, 182), (200, nil)]
        for (mtu, maxFrame) in cases {
            let frames = try Sap.encode(service: 7, message: message, mtu: mtu, maxFrame: maxFrame)
            XCTAssertGreaterThan(frames.count, 1)
            XCTAssertTrue(frames.allSatisfy { $0.count <= (maxFrame ?? mtu) })
            let reassembler = SapReassembler()
            var result: (service: Int, message: [UInt8])?
            for frame in frames { result = reassembler.push(try Sap.decode(frame)) }
            XCTAssertEqual(result?.service, 7)
            XCTAssertEqual(result?.message, message)
        }
    }

    func testCapabilityReplyOnlyChangesOpcode() throws {
        var request = [UInt8](repeating: 0, count: 105)
        request[0] = 104
        request[1] = 0x14
        request[0x2C] = 0x01
        request[0x2D] = 0xF4
        XCTAssertTrue(Sap.isCapabilityRequest(request))
        XCTAssertEqual(Sap.transportMtu(request), 500)
        let reply = try Sap.capabilityReply(request)
        XCTAssertEqual(reply[1], 0x15)
        XCTAssertTrue(request.indices.filter { $0 != 1 }.allSatisfy { request[$0] == reply[$0] })
    }

    func testInitSettingsVector() {
        // 2023-11-14 22:13:20Z, Moscou (UTC+3), idioma 57.
        let msg = Oobe.initSettings(localeId: 57, date: Date(timeIntervalSince1970: 1_700_000_000),
                                    timeZone: TimeZone(secondsFromGMT: 3 * 3600)!)
        XCTAssertEqual(msg.hex, "830139000200030a313730303030303030300400302a0501")
    }

    func testBattery() {
        XCTAssertEqual(BandSettings.parseBattery([UInt8](hex: "42053a0600")!),
                       BandSettings.Battery(percent: 58, charging: false))
        XCTAssertEqual(BandSettings.parseBattery([UInt8](hex: "4205640601")!),
                       BandSettings.Battery(percent: 100, charging: true))
        XCTAssertNil(BandSettings.parseBattery([UInt8](hex: "02053a0600")!))
    }

    func testNotificationLayoutAndAck() {
        let msg = BandNotification.new(sequence: 7, title: "Oi", body: "Mensagem", appName: "Teste",
                                       package: "com.example", appId: 20,
                                       date: Date(timeIntervalSince1970: 0), category: "msg")
        XCTAssertEqual(Array(msg[0...1]), [0x80, 11])
        XCTAssertTrue(msg.hex.contains("040800" + Array("Mensagem".utf8).hex))
        XCTAssertTrue(msg.hex.hasSuffix("120b" + Array("com.example".utf8).hex))
        let ack = BandNotification.parseAck([UInt8](hex: "4001070000000b01")!)
        XCTAssertEqual(ack?.sequence, 7)
        XCTAssertEqual(ack?.accepted, true)
    }

    func testCallContactMatchesOfficialBuilder() {
        let agent = Array(BandCall.agentName.utf8)
        var expected: [UInt8] = [0x82, 7, 0, 1, 7, 1, 0, 0, 0, 5, UInt8(agent.count)] + agent
        expected += [6] + (0..<8).map { UInt8(truncatingIfNeeded: Int64(1_700_000_000_000) >> ($0 * 8)) }
        expected += [4, 3] + Array("Ana".utf8) + [3, 4] + Array("1234".utf8) + [9, 0]
        XCTAssertEqual(BandCall.contact(name: "Ana", number: "1234",
                                        date: Date(timeIntervalSince1970: 1_700_000_000)), expected)
        XCTAssertEqual(BandCall.state(.ringing), [3, 1])
        XCTAssertEqual(Array(BandCall.missed(name: "", number: "99")[0...1]), [0x86, 3])
    }

    func testLocaleIds() {
        XCTAssertEqual(BandLocale.id(forLanguageTag: "pt-BR"), 82)
        XCTAssertEqual(BandLocale.id(forLanguageTag: "pt_BR"), 82)
        XCTAssertEqual(BandLocale.id(forLanguageTag: "en-GB"), 13)
        XCTAssertEqual(BandLocale.id(forLanguageTag: "xx"), 13)
    }

    func testFirmwareString() {
        XCTAssertEqual(Oobe.firmware(in: [0x41, 0x01] + Array("..R390XXU0AZA3".utf8) + [0]), "R390XXU0AZA3")
    }
}
