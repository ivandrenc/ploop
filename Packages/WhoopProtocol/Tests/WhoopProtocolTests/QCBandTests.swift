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

    func testSetTimeIsBCDInBandTimeZone() {
        let date = Date(timeIntervalSince1970: 1_704_164_645)   // 2024-01-02 03:04:05 UTC
        XCTAssertEqual(QCBand.setTime(date, timeZone: TimeZone(identifier: "UTC")!),
                       Self.hex("01240102030405010000000000000035"))
    }

    func testReadHeartRateLogEncodesLittleEndianDayStart() {
        XCTAssertEqual(QCBand.readHeartRateLog(bandDayStart: 1_700_006_400),
                       QCBand.packet(0x15, [0x00, 0x0A, 0x54, 0x65]))
    }

    func testBandSecondsAddsZoneOffset() {
        let ny = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(QCBand.bandSeconds(1_700_006_400, timeZone: ny), 1_700_006_400 - 5 * 3_600)
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
                       .notification(kind: 1, data: [UInt8](repeating: 0, count: 13)))
    }

    func testParseRejectsBadChecksumAndLength() {
        XCTAssertNil(QCBand.parse(Self.hex("03640000000000000000000000000068")))
        XCTAssertNil(QCBand.parse([0x03, 0x64, 0x67]))
    }

    // MARK: - Slot logs

    func testHeartRateLogReassembly() throws {
        var parser = QCBand.SlotLogParser(kind: .heartRate)
        // colmi_r02_client example header: 24 packets, 5-minute slots. Use 3 packets here.
        XCTAssertNil(parser.feed(QCBand.packet(0x15, [0x00, 0x03, 0x05])))
        let ts: [UInt8] = [0x00, 0x0A, 0x54, 0x65]
        XCTAssertNil(parser.feed(QCBand.packet(0x15, [0x01] + ts + [60, 0, 62, 0, 0, 0, 0, 0, 70])))
        let last = parser.feed(QCBand.packet(0x15, [0x02, 80] + [UInt8](repeating: 0, count: 12)))

        let samples = try XCTUnwrap(last)
        XCTAssertEqual(samples.map(\.minuteOfDay), [0, 10, 40, 45])
        XCTAssertEqual(samples.map(\.value), [60, 62, 70, 80])
    }

    func testHRVLogUsesThirtyMinuteSlots() {
        var parser = QCBand.SlotLogParser(kind: .hrv)
        _ = parser.feed(QCBand.packet(0x39, [0x00, 0x02]))
        let samples = parser.feed(QCBand.packet(0x39, [0x01, 0x00, 40, 0, 55]))
        XCTAssertEqual(samples, [QCBand.DaySample(minuteOfDay: 0, value: 40),
                                 QCBand.DaySample(minuteOfDay: 60, value: 55)])
    }

    func testSlotLogNoData() {
        var parser = QCBand.SlotLogParser(kind: .heartRate)
        XCTAssertEqual(parser.feed(QCBand.packet(0x15, [0xFF]))?.count, 0)
    }

    func testHeartRateLogHeaderExampleChecksum() {
        // colmi_r02_client example header bytes, checksum included.
        XCTAssertEqual(QCBand.packet(0x15, [0x00, 0x18, 0x05]), Self.hex("15001805000000000000000000000032"))
    }

    // MARK: - Steps

    func testStepsBucket() {
        var parser = QCBand.StepsParser()
        XCTAssertNil(parser.feed(Self.hex("43f00501000000000000000000000039")))
        // colmi_r02_client example: 2023-08-13, quarter 16, 200 kcal-units, 48 steps, 27 m. Last of 1.
        let out = parser.feed(QCBand.packet(0x43, [0x23, 0x08, 0x13, 0x10, 0x00, 0x01, 0xC8, 0x00, 0x30, 0x00, 0x1B, 0x00]))
        XCTAssertEqual(out, [QCBand.StepBucket(year: 2023, month: 8, day: 13, quarter: 16,
                                               steps: 48, calories: 200, distanceM: 27)])
        XCTAssertEqual(out?.first?.dayString, "2023-08-13")
    }

    // MARK: - Big data

    func testBigDataAssemblyAcrossNotifications() {
        var a = QCBand.BigDataAssembler()
        XCTAssertNil(a.feed([0xBC, 0x27, 0x04, 0x00, 0x00, 0x00, 0x01]))
        XCTAssertEqual(a.feed([0x02, 0x03, 0x04, 0x99]), [0xBC, 0x27, 0x04, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04])
    }

    func testParseSleep() {
        // 1 night, today: 23:00 (1380) → 07:00 (420); light 120, deep 60, awake 10.
        let body: [UInt8] = [0x01, 0x00, 10, 0x64, 0x05, 0xA4, 0x01, 2, 120, 3, 60, 5, 10]
        let reply: [UInt8] = [0xBC, 0x27, UInt8(body.count), 0x00, 0x00, 0x00] + body
        let nights = QCBand.parseSleep(reply)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights.first?.startMinute, 1_380)
        XCTAssertEqual(nights.first?.endMinute, 420)
        XCTAssertEqual(nights.first?.minutes(.light), 120)
        XCTAssertEqual(nights.first?.minutes(.deep), 60)
        XCTAssertEqual(nights.first?.minutes(.awake), 10)
    }

    func testParseSpO2() {
        var day: [UInt8] = [0x00]
        for h in 0..<24 { day += h == 3 ? [95, 98] : [0, 0] }
        let reply: [UInt8] = [0xBC, 0x2A, UInt8(day.count), 0x00, 0x00, 0x00] + day
        XCTAssertEqual(QCBand.parseSpO2(reply), [QCBand.SpO2Hour(daysAgo: 0, hour: 3, percent: 97)])
    }
}
