import XCTest
@testable import WhoopProtocol

final class QCBandTests: XCTestCase {

    static func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            out.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return out
    }

    // MARK: - Building

    func testRequestsMatchCapturedBytes() {
        // Sent by hand from nRF Connect to an H59 band; both were accepted.
        XCTAssertEqual(QCBand.batteryRequest(), Self.hex("03000000000000000000000000000003"))
        XCTAssertEqual(QCBand.startRealtime(), Self.hex("6901010000000000000000000000006B"))
        XCTAssertEqual(QCBand.continueRealtime(), Self.hex("1E330000000000000000000000000051"))
    }

    func testPacketIsSixteenBytesWithTruncatedData() {
        let p = QCBand.packet(0x10, [UInt8](repeating: 0xFF, count: 20))
        XCTAssertEqual(p.count, 16)
        XCTAssertEqual(p[14], 0xFF)
        XCTAssertEqual(p[15], QCBand.checksum(p))
    }

    func testSetTimeIsBCDInUTC() {
        let date = Date(timeIntervalSince1970: 1_704_164_645)   // 2024-01-02 03:04:05 UTC
        XCTAssertEqual(QCBand.setTime(date), Self.hex("01240102030405010000000000000035"))
    }

    func testReadHeartRateLogEncodesLittleEndianDayStart() {
        XCTAssertEqual(QCBand.readHeartRateLog(dayStartUnix: 1_700_006_400),
                       QCBand.packet(0x15, [0x00, 0x0A, 0x54, 0x65]))
    }

    func testUTCDayStart() {
        XCTAssertEqual(QCBand.utcDayStart(1_700_006_400), 1_700_006_400)
        XCTAssertEqual(QCBand.utcDayStart(1_700_006_400 + 86_399), 1_700_006_400)
    }

    // MARK: - Parsing

    func testParseBatteryReplies() {
        // Captured from the H59 band: 100 %, not charging.
        XCTAssertEqual(QCBand.parse(Self.hex("03640000000000000000000000000067")),
                       .battery(percent: 100, charging: false))
        // colmi_r02_client example: 64 %.
        XCTAssertEqual(QCBand.parse(Self.hex("03400000000000000000000000000043")),
                       .battery(percent: 64, charging: false))
    }

    func testParseRealtime() {
        // Captured from the H59 band: still measuring.
        XCTAssertEqual(QCBand.parse(Self.hex("6901000000000000000000000000006A")),
                       .realtime(kind: 1, value: 0))
        XCTAssertEqual(QCBand.parse(QCBand.packet(0x69, [0x01, 0x00, 72])),
                       .realtime(kind: 1, value: 72))
        XCTAssertEqual(QCBand.parse(QCBand.packet(0x69, [0x01, 0x02])),
                       .realtimeError(kind: 1, code: 2))
    }

    func testParseNotification() {
        // Captured from the H59 band ("st").
        XCTAssertEqual(QCBand.parse(Self.hex("73010000000000000000000000000074")),
                       .notification(kind: 1))
    }

    func testParseRejectsBadChecksumAndLength() {
        XCTAssertNil(QCBand.parse(Self.hex("03640000000000000000000000000068")))
        XCTAssertNil(QCBand.parse([0x03, 0x64, 0x67]))
    }

    // MARK: - Heart-rate log

    func testHeartRateLogReassembly() throws {
        let day = 1_700_006_400
        var parser = QCBand.HeartRateLogParser()
        let now = day + 86_400

        // colmi_r02_client example header: 24 packets, 5-minute slots. Use 3 packets here.
        XCTAssertNil(parser.feed(QCBand.packet(0x15, [0x00, 0x03, 0x05]), now: now))
        let ts: [UInt8] = [0x00, 0x0A, 0x54, 0x65]
        XCTAssertNil(parser.feed(QCBand.packet(0x15, [0x01] + ts + [60, 0, 62, 0, 0, 0, 0, 0, 70]), now: now))
        let last = parser.feed(QCBand.packet(0x15, [0x02, 80] + [UInt8](repeating: 0, count: 12)), now: now)

        let samples = try XCTUnwrap(last)
        XCTAssertEqual(samples.map(\.ts), [day, day + 600, day + 2_400, day + 2_700])
        XCTAssertEqual(samples.map(\.bpm), [60, 62, 70, 80])
    }

    func testHeartRateLogDropsFutureSlots() {
        let day = 1_700_006_400
        var parser = QCBand.HeartRateLogParser()
        _ = parser.feed(QCBand.packet(0x15, [0x00, 0x02, 0x05]), now: day + 300)
        let samples = parser.feed(QCBand.packet(0x15, [0x01, 0x00, 0x0A, 0x54, 0x65, 60, 61, 62]),
                                  now: day + 300)
        XCTAssertEqual(samples?.map(\.bpm), [60, 61])
    }

    func testHeartRateLogNoData() {
        var parser = QCBand.HeartRateLogParser()
        XCTAssertEqual(parser.feed(QCBand.packet(0x15, [0xFF]), now: 0)?.count, 0)
    }

    func testHeartRateLogHeaderExampleChecksum() {
        // colmi_r02_client example header bytes, checksum included.
        XCTAssertEqual(QCBand.packet(0x15, [0x00, 0x18, 0x05]), Self.hex("15001805000000000000000000000032"))
    }
}
