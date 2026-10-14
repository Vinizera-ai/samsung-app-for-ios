// Mesmos vetores de tools/tests/test_protocol.py (MediaTest): fixtures do SAMessageData.Builder original.
import XCTest
@testable import Fit3Kit

final class MediaTests: XCTestCase {
    func testCapabilityAndVolumeMatchStockBuilder() {
        XCTAssertEqual(BandMedia.capability(maxVolume: 160, warningVolume: 106),
                       [0x54, 2, 1, 0xA0, 0, 0, 0, 2, 0x6A, 0, 0, 0])
        XCTAssertEqual(BandMedia.volumeInfo(80, headset: true), [0x55, 2, 1, 80, 0, 0, 0, 2, 2])
        XCTAssertEqual(BandMedia.volumeInfo(0, headset: false), [0x55, 2, 1, 0, 0, 0, 0, 2, 1])
    }

    func testMediaChangedEchoesScreenState() {
        XCTAssertEqual(BandMedia.screenState([1, 1, 2]), 2)
        for state: UInt8 in 0...2 {
            XCTAssertEqual(BandMedia.mediaChanged(screenState: state), [0x57, 1, 1, state])
        }
    }

    func testAppCount() {
        XCTAssertEqual(Array(BandMedia.appCount(appId: "com.spotify.music")[0..<6]), [0xD8, 2, 1, 1, 2, 17])
        XCTAssertEqual(BandMedia.appCount(appId: ""), [0xD8, 2, 1, 0, 2, 0])
    }

    func testRemoteControlPressAndRelease() {
        XCTAssertEqual(BandMedia.parseRemote([0x04, 1, 4, 2, 2]), BandMedia.Remote(action: .next, pressed: true))
        XCTAssertEqual(BandMedia.parseRemote([0x04, 1, 2, 2, 1]), BandMedia.Remote(action: .playPause, pressed: false))
        XCTAssertEqual(BandMedia.parseRemote([0x04, 1, 3]), BandMedia.Remote(action: .previous, pressed: true))
        XCTAssertNil(BandMedia.parseRemote([0x44, 1, 4]))
    }

    func testVolumeControl() {
        XCTAssertEqual(BandMedia.parseVolume([7, 1, 1, 2, 7]), BandMedia.Volume(action: .set, value: 7))
        XCTAssertEqual(BandMedia.parseVolume([7, 1, 2]), BandMedia.Volume(action: .up, value: nil))
        XCTAssertEqual(BandMedia.parseVolume([7, 1, 2, 2, 1, 0, 0, 0]), BandMedia.Volume(action: .up, value: 1))
        XCTAssertEqual(BandMedia.parseVolume([7, 1, 1, 2, 80, 0, 0, 0]), BandMedia.Volume(action: .set, value: 80))
        XCTAssertEqual(BandMedia.parseVolume([7, 1, 3]), BandMedia.Volume(action: .down, value: nil))
    }

    func testRequestedAppId() {
        let app = Array("org.example.player".utf8)
        XCTAssertEqual(BandMedia.requestedAppId([9, 1, UInt8(app.count)] + app), "org.example.player")
        XCTAssertEqual(BandMedia.requestedAppId([0x89, 1, 1, UInt8(app.count)] + app), "org.example.player")
        XCTAssertNil(BandMedia.requestedAppId([0x89, 1, 1, 50]))
    }

    func testMetadataAndPlaybackState() {
        let meta = BandMedia.metadata(title: "Música", artist: "Artista", durationMs: 90_000, appId: "com.apple.Music")
        XCTAssertEqual(Array(meta[0...1]), [0xD1, 5])
        XCTAssertTrue(meta.hex.contains("01" + "905f010000000000"))
        XCTAssertTrue(meta.hex.hasSuffix("050f" + Array("com.apple.Music".utf8).hex))
        let stopped = BandMedia.playbackState(.stopped, positionMs: 0, appId: "")
        XCTAssertEqual(Array(stopped[0...3]), [0xD2, 4, 1, 1])
        XCTAssertTrue(stopped.hex.contains("04" + String(repeating: "ff", count: 8)))
    }
}
