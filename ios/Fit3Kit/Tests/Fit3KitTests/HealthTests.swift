// Mesmos vetores de tools/tests/test_health.py (capturas de pulseiras AZA3 via Fit3-App).
import XCTest
@testable import Fit3Kit

final class HealthTests: XCTestCase {
    static let capturedSteps = [UInt8](hex:
        "82 03 E0 19 27 07 01 " +
        "05 30 8F 19 45 01 F4 8E 19 45 02 30 8F 19 45 03 80 C8 A4 00 " +
        "10 08 00 00 00 11 E0 16 F2 40 12 67 67 EB 3E 13 F2 19 E0 3E " +
        "14 00 00 00 00 15 08 00 00 00 16 C8 1B 00 00 17 03 00 " +
        "05 E4 8F 19 45 01 A8 8F 19 45 02 E4 8F 19 45 03 80 C8 A4 00 " +
        "10 15 00 00 00 11 E0 A6 67 41 12 C3 02 EE 3F 13 13 50 A4 3F " +
        "14 00 00 00 00 15 15 00 00 00 16 E0 38 00 00 17 03 00")!

    func le4(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
    func bandTs(_ d: Date) -> [UInt8] { le4(Int(d.timeIntervalSince1970) - Int(BandHealth.epoch1990)) }
    /// Junta pedaços sem cadeias de `+` (que travam o verificador de tipos do Swift).
    func bytes(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }
    func field(_ id: UInt8, _ v: [UInt8]) -> [UInt8] { bytes([id], v) }
    func vitalPacket(_ type: UInt8, _ fields: [UInt8]...) -> [UInt8] {
        let record = fields.flatMap { $0 }
        return bytes([0x82, 3, 0xE0, 1, 0, type, 0], le4(record.count), record, [5, 0])
    }

    func testGMCapabilityFromRealBand() {
        let r = BandHealth.reply(for: [0xA2, 0x02, 0xE0, 0x17, 0x27, 0xE1, 0x2D, 0x01])
        XCTAssertEqual(r.event, .gmCapability)
        XCTAssertEqual(Array(r.reply![0...1]), [0xE2, 6])
        XCTAssertEqual(Array(r.reply!.suffix(6)), [0xE0, 0x17, 0x27, 0xE1, 0x2D, 0x01])
    }

    func testWearableCapabilityEchoesSequenceAndFragments() throws {
        let r = BandHealth.reply(for: [0xA0, 0x17, 0xE0, 0x3A, 0x27, 0xA0, 0x01, 0xA1, 0x04, 0x33, 0xA3, 0x11])
        XCTAssertEqual(r.event, .wearableCapability)
        let reply = try XCTUnwrap(r.reply)
        XCTAssertEqual(reply[0], 0xE0)
        XCTAssertEqual(Array(reply[2...4]), [0xE0, 0x3A, 0x27])
        XCTAssertGreaterThan(reply.count, 500)
        XCTAssertGreaterThan(try Sap.encode(service: 10, message: reply, mtu: 500, maxFrame: 182).count, 1)
        for (_, text) in BandHealth.capabilityStrings { XCTAssertLessThanOrEqual(text.utf8.count, 255) }
    }

    func testAcksPreserveSequence() {
        for seq in [0, 255, 256, 65535] {
            let lo = UInt8(seq & 0xFF), hi = UInt8(seq >> 8)
            XCTAssertEqual(BandHealth.reply(for: [0x82, 1, 0xE0, lo, hi]).reply, [0x42, 2, 0xE0, lo, hi, 4, 2, 1, 1])
            XCTAssertEqual(BandHealth.reply(for: [3, 0xE0, lo, hi]).reply, [0x43, 0xE0, lo, hi, 4, 2, 1, 1])
        }
        XCTAssertNil(BandHealth.reply(for: [0x82]).reply)
        XCTAssertNil(BandHealth.reply(for: [0x03]).reply)
        XCTAssertEqual(BandHealth.reply(for: [0x01]).reply, [0x41])
        XCTAssertEqual(BandHealth.reply(for: [0x04]).reply, [0x44])
    }

    func testRequestDataMatchesStock31Bytes() {
        let now = Date(timeIntervalSince1970: TimeInterval(BandHealth.epoch1990 + 1_234_567))
        let req = BandHealth.requestData(sequence: 10001, now: now)
        XCTAssertEqual(req.count, 31)
        XCTAssertEqual(Array(req[0..<14]), [3, 0xE0, 0x11, 0x27, 5, 25, 1, 0, 2, 0, 0, 3, 4, 51])
        XCTAssertEqual(BandHealth.i32(req, 25), 1_234_567)
        XCTAssertEqual(BandHealth.sequence(req), 10001)
    }

    func testCapturedStepIntervals() throws {
        let bins = try XCTUnwrap(BandHealth.parseStepBins(Self.capturedSteps))
        XCTAssertEqual(bins.map(\.count), [8, 21])
        XCTAssertEqual(bins.map(\.walk).reduce(0, +), 29)
        XCTAssertEqual(bins[0].end.timeIntervalSince(bins[0].start), 60)
        XCTAssertEqual(bins[0].distanceMeters, 7.565, accuracy: 0.01)
    }

    func testLargeDataTwoChunks() throws {
        let payload = Self.capturedSteps
        let rx = LargeDataReceiver()
        let first = try XCTUnwrap(rx.accept([0x3F, 0x08, 0, 0, 0, 0] + payload[0..<60]))
        XCTAssertNil(first.payload)
        XCTAssertNil(first.ack)
        let last = try XCTUnwrap(rx.accept([0x3F, 0x0A, 1, 0, 0, 0] + payload[60...]))
        XCTAssertEqual(last.payload, payload)
        XCTAssertEqual(last.ack, [0x3E, 0x09, 2, 0, 0, 0])
        XCTAssertEqual(BandHealth.reply(for: payload).reply, [0x42, 2, 0xE0, 0x19, 0x27, 4, 2, 1, 1])

        let rx2 = LargeDataReceiver()
        _ = rx2.accept([0x3F, 0x08, 0, 0, 0, 0, 1, 2])
        XCTAssertEqual(rx2.accept([0x3F, 0x0A, 2, 0, 0, 0, 3])?.ack, [0x3E, 0x08, 2, 0, 0, 0])
    }

    func testVitals() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let hr = try XCTUnwrap(BandHealth.parseVitals(vitalPacket(10,
            field(1, bandTs(now.addingTimeInterval(-120))), field(2, bandTs(now.addingTimeInterval(-60))),
            field(32, [75]), field(33, [60]), field(34, [90])))?.first)
        XCTAssertEqual([hr.value, hr.min, hr.max], [75, 60, 90])
        XCTAssertEqual(hr.measuredAt, now.addingTimeInterval(-60))

        let spo2 = try XCTUnwrap(BandHealth.parseVitals(vitalPacket(112, field(1, bandTs(now)),
                                                                    field(169, [97]), field(170, [78])))?.first)
        XCTAssertEqual(spo2.value, 97)

        let sleep = try XCTUnwrap(BandHealth.parseVitals(vitalPacket(16,
            field(1, bandTs(now.addingTimeInterval(-440 * 60))), field(2, bandTs(now)), field(83, [82])))?.first)
        XCTAssertEqual(sleep.score, 82)
        XCTAssertEqual(sleep.end!.timeIntervalSince(sleep.start!), 440 * 60)

        var bad = vitalPacket(112, field(1, bandTs(now)), field(169, [98]))
        bad[7] = 0x7F
        XCTAssertNil(BandHealth.parseVitals(bad))
    }

    func testSleepStages() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000), end = start.addingTimeInterval(8 * 3600)
        let pkt = bytes([0x82, 3, 0xE0, 1, 0, 17, 0],
                        field(1, bandTs(start)), field(2, bandTs(end)), field(3, le4(0)), field(5, bandTs(end)),
                        field(82, le4(BandHealth.sleepDeep)), field(85, [UInt8](repeating: 1, count: 16)),
                        field(151, le4(1)), field(153, le4(1)))
        let stage = try XCTUnwrap(BandHealth.parseSleepStages(pkt)?.first)
        XCTAssertEqual(stage, BandHealth.SleepStage(sleepId: String(repeating: "01", count: 16),
                                                    start: start, end: end, kind: BandHealth.sleepDeep))
        XCTAssertNil(BandHealth.parseSleepStages(Array(pkt.dropLast())))
        var unknown = pkt
        unknown[7] = 99
        XCTAssertNil(BandHealth.parseSleepStages(unknown))
    }
}
