import Foundation

/// Pure protocol for QC Wireless bands and rings (the hardware behind the "QWatch Pro" / "QRing"
/// apps and the Colmi R0x rings). Platform-pure like `DeviceFamily`: UUIDs are plain strings and
/// the app layer wraps them in `CBUUID(string:)`.
///
/// Two channels:
/// - **Command channel** (6E40FFF0): every packet in both directions is exactly 16 bytes,
///   `[cmd][14 data bytes][checksum]`, checksum = sum of bytes 0…14 truncated to 8 bits.
/// - **Big-data channel** (DE5BF728): variable-length `[0xBC][type][len u16 LE][2 bytes][len bytes]`
///   replies that may span several notifications (sleep, SpO2 history).
///
/// The band keeps its clock in LOCAL time and stores history per local day; "days ago" and
/// "minute of day" values below are local. Command values follow tahnok/colmi_r02_client and
/// Gadgetbridge's Colmi support; confirmed on an "H59" band (battery `03 64 … 67`, realtime `69 01 00 …`).
public enum QCBand {

    // MARK: GATT

    public static let serviceUUIDString = "6e40fff0-b5a3-f393-e0a9-e50e24dcca9e"
    /// App → band (write without response).
    public static let rxCharUUIDString  = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
    /// Band → app (notify).
    public static let txCharUUIDString  = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
    public static let bigDataServiceUUIDString    = "de5bf728-d711-4e47-af26-65e3012a5dc7"
    /// App → band big-data requests (write without response).
    public static let bigDataWriteCharUUIDString  = "de5bf72a-d711-4e47-af26-65e3012a5dc7"
    /// Band → app big-data replies (notify).
    public static let bigDataNotifyCharUUIDString = "de5bf729-d711-4e47-af26-65e3012a5dc7"
    /// What the band actually advertises (it does NOT advertise the 6E40FFF0 service), so scans
    /// filter on this and the connection confirms the band by discovering `serviceUUIDString`.
    public static let advertisedServiceUUIDString = "fee7"

    public static let packetLength = 16

    // MARK: Commands

    public enum Command: UInt8, Sendable {
        case setTime            = 0x01
        case battery            = 0x03
        case readHeartRateLog   = 0x15
        case heartRateLogConfig = 0x16
        case realtimeContinue   = 0x1E
        case spo2LogConfig      = 0x2C
        case hrvLogConfig       = 0x38
        case readHRVLog         = 0x39
        case readSteps          = 0x43
        case startRealtime      = 0x69
        case stopRealtime       = 0x6A
        /// Unprompted band → app notice; data[1] says what changed.
        case notification       = 0x73
        case bigData            = 0xBC
    }

    /// `notification` kinds (data[1]).
    public enum NotificationKind: UInt8, Sendable {
        case newHeartRate = 0x01
        case newSpO2      = 0x03
        case newSteps     = 0x04
        case battery      = 0x0C
    }

    /// Reading kinds for START/STOP realtime (data[0]).
    public enum RealtimeKind: UInt8, Sendable {
        case heartRate = 1
        case spo2      = 3
    }

    public enum BigDataType: UInt8, Sendable {
        case sleep = 0x27
        case spo2  = 0x2A
    }

    // MARK: Building

    public static func checksum(_ bytes: [UInt8]) -> UInt8 {
        UInt8(truncatingIfNeeded: bytes.prefix(packetLength - 1).reduce(0) { $0 + Int($1) })
    }

    /// A well-formed 16-byte packet. `data` longer than 14 bytes is truncated.
    public static func packet(_ cmd: UInt8, _ data: [UInt8] = []) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: packetLength)
        p[0] = cmd
        for (i, b) in data.prefix(packetLength - 2).enumerated() { p[i + 1] = b }
        p[packetLength - 1] = checksum(p)
        return p
    }

    public static func packet(_ cmd: Command, _ data: [UInt8] = []) -> [UInt8] {
        packet(cmd.rawValue, data)
    }

    public static func batteryRequest() -> [UInt8] { packet(.battery) }

    /// SET_TIME: BCD `[yy, MM, dd, HH, mm, ss]` in the band's (local) time zone, then a language
    /// byte (1 = English).
    public static func setTime(_ date: Date, timeZone: TimeZone = .current) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let fields = [(c.year ?? 2000) % 100, c.month ?? 1, c.day ?? 1,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0]
        return packet(.setTime, fields.map(bcd) + [0x01])
    }

    static func bcd(_ v: Int) -> UInt8 { UInt8(((v / 10) << 4) | (v % 10)) }
    static func fromBCD(_ b: UInt8) -> Int { Int(b >> 4) * 10 + Int(b & 0x0F) }

    public static func startRealtime(_ kind: RealtimeKind = .heartRate) -> [UInt8] {
        packet(.startRealtime, [kind.rawValue, 0x01])
    }

    public static func stopRealtime(_ kind: RealtimeKind = .heartRate) -> [UInt8] {
        packet(.stopRealtime, [kind.rawValue, 0x00, 0x00])
    }

    /// Keeps a realtime heart-rate session from lapsing (the band stops on its own otherwise).
    public static func continueRealtime() -> [UInt8] { packet(.realtimeContinue, [0x33]) }

    /// Turn the band's own periodic heart-rate logging on, every `intervalMinutes`.
    public static func enableHeartRateLog(intervalMinutes: UInt8 = 5) -> [UInt8] {
        packet(.heartRateLogConfig, [0x02, 0x01, intervalMinutes])
    }

    /// Turn on the band's automatic SpO2 / HRV logging (no-ops on firmware without them).
    public static func enableSpO2Log() -> [UInt8] { packet(.spo2LogConfig, [0x02, 0x01]) }
    public static func enableHRVLog() -> [UInt8] { packet(.hrvLogConfig, [0x02, 0x01]) }

    /// Request the heart-rate log for the day starting at `bandDayStart`, a local midnight
    /// expressed in the band's clock (see `bandSeconds`).
    public static func readHeartRateLog(bandDayStart: Int) -> [UInt8] {
        packet(.readHeartRateLog, le32(bandDayStart))
    }

    public static func readHRVLog(daysAgo: Int) -> [UInt8] { packet(.readHRVLog, le32(daysAgo)) }

    public static func readSteps(daysAgo: Int) -> [UInt8] {
        packet(.readSteps, [UInt8(clamping: daysAgo), 0x0F, 0x00, 0x5F, 0x01])
    }

    /// Big-data request (raw 7 bytes, no padding/checksum) for every stored day of `type`.
    public static func bigDataRequest(_ type: BigDataType) -> [UInt8] {
        [Command.bigData.rawValue, type.rawValue, 0x01, 0x00, 0xFF, 0x00, 0xFF]
    }

    static func le32(_ v: Int) -> [UInt8] {
        let t = UInt32(truncatingIfNeeded: v)
        return [UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8(t >> 24)]
    }

    // MARK: Local-time helpers

    /// A unix time as the band's local clock counts it (unix + the zone's UTC offset).
    public static func bandSeconds(_ unix: Int, timeZone: TimeZone = .current) -> Int {
        unix + timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Unix seconds of local midnight `daysAgo` days before `now`.
    public static func localDayStart(daysAgo: Int, now: Date, timeZone: TimeZone = .current) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let day = cal.date(byAdding: .day, value: -daysAgo, to: today) ?? today
        return Int(day.timeIntervalSince1970)
    }

    /// Unix seconds of local midnight on a calendar date.
    public static func localDayStart(year: Int, month: Int, day: Int,
                                     timeZone: TimeZone = .current) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: year, month: month, day: day))
            .map { Int($0.timeIntervalSince1970) }
    }

    // MARK: Parsing (command channel)

    public enum Reply: Equatable, Sendable {
        case battery(percent: Int, charging: Bool)
        /// `value == 0` means the band is still measuring (normal for the first few replies).
        case realtime(kind: UInt8, value: Int)
        case realtimeError(kind: UInt8, code: UInt8)
        case notification(kind: UInt8, data: [UInt8])
        /// One packet of a multi-packet history reply; feed it to the matching parser.
        case heartRateLogPart
        case hrvLogPart
        case stepsPart
        /// Anything else with a valid checksum (set-time capabilities, config acks, …).
        case other(cmd: UInt8)
    }

    /// Parse one notification. nil if it isn't a 16-byte packet with a valid checksum.
    public static func parse(_ p: [UInt8]) -> Reply? {
        guard p.count == packetLength, p[packetLength - 1] == checksum(p) else { return nil }
        switch Command(rawValue: p[0]) {
        case .battery:
            return .battery(percent: Int(p[1]), charging: p[2] != 0)
        case .startRealtime:
            return p[2] == 0 ? .realtime(kind: p[1], value: Int(p[3]))
                             : .realtimeError(kind: p[1], code: p[2])
        case .notification:
            return .notification(kind: p[1], data: Array(p[2..<15]))
        case .readHeartRateLog:
            return .heartRateLogPart
        case .readHRVLog:
            return .hrvLogPart
        case .readSteps:
            return .stepsPart
        default:
            return .other(cmd: p[0])
        }
    }

    /// One value at a minute of a (local) day.
    public struct DaySample: Equatable, Sendable {
        public let minuteOfDay: Int
        public let value: Int
        public init(minuteOfDay: Int, value: Int) { self.minuteOfDay = minuteOfDay; self.value = value }
    }

    /// Reassembles the slot logs: a header (`sub 0`), then `sub 1…n-1` carrying one value per
    /// slot (0 = no reading). `sub 0xFF` = no data for that day.
    /// - Heart rate (0x15): header `[2]` packet count, `[3]` minutes per slot; `sub 1` = u32 day
    ///   timestamp + 9 slots; later packets 13 slots.
    /// - HRV (0x39): header `[2]` packet count, 30-minute slots; `sub 1` = 1 unknown byte + 12 slots;
    ///   later packets 13 slots.
    public struct SlotLogParser: Sendable {
        public enum Kind: Sendable { case heartRate, hrv }
        public let kind: Kind
        private var size = 0
        private var minutesPerSlot: Int
        private var slots: [UInt8] = []
        private var gotFirst = false

        public init(kind: Kind) {
            self.kind = kind
            self.minutesPerSlot = kind == .heartRate ? 5 : 30
        }

        /// Feed one packet. Returns the finished log (non-zero slots only) when the last packet
        /// arrives, `[]` for "no data", else nil.
        public mutating func feed(_ p: [UInt8]) -> [DaySample]? {
            let cmd: Command = kind == .heartRate ? .readHeartRateLog : .readHRVLog
            guard p.count == QCBand.packetLength, p[0] == cmd.rawValue else { return nil }
            let sub = Int(p[1])
            switch sub {
            case 0xFF:
                reset()
                return []
            case 0:
                reset()
                size = Int(p[2])
                if kind == .heartRate, p[3] > 0 { minutesPerSlot = Int(p[3]) }
                if size <= 1 { return [] }
                return nil
            case 1:
                slots = Array(p[(kind == .heartRate ? 6 : 3)..<15])
                gotFirst = true
            default:
                guard gotFirst else { return nil }   // missed sub 1 — wait for a fresh log
                slots += p[2..<15]
            }
            guard size > 0, sub >= size - 1 else { return nil }
            let step = minutesPerSlot
            let out = slots.enumerated().compactMap { i, v -> DaySample? in
                let minute = i * step
                guard v > 0, minute < 1_440 else { return nil }
                return DaySample(minuteOfDay: minute, value: Int(v))
            }
            reset()
            return out
        }

        private mutating func reset() {
            size = 0; slots = []; gotFirst = false
            minutesPerSlot = kind == .heartRate ? 5 : 30
        }
    }

    /// One 15-minute activity bucket from the steps history (local date).
    public struct StepBucket: Equatable, Sendable {
        public let year: Int, month: Int, day: Int
        /// Quarter-hour of the day, 0…95.
        public let quarter: Int
        public let steps: Int
        public let calories: Int
        public let distanceM: Int
        public init(year: Int, month: Int, day: Int, quarter: Int, steps: Int, calories: Int, distanceM: Int) {
            self.year = year; self.month = month; self.day = day; self.quarter = quarter
            self.steps = steps; self.calories = calories; self.distanceM = distanceM
        }
        public var dayString: String { String(format: "%04d-%02d-%02d", year, month, day) }
    }

    /// Reassembles a steps reply (0x43): `F0` header, then one packet per bucket
    /// `[yy][MM][dd] BCD, [quarter], [index], [count], calories u16, steps u16, distance u16`
    /// (all LE). `FF` = no data for that day.
    public struct StepsParser: Sendable {
        private var buckets: [StepBucket] = []
        public init() {}

        public mutating func feed(_ p: [UInt8]) -> [StepBucket]? {
            guard p.count == QCBand.packetLength, p[0] == Command.readSteps.rawValue else { return nil }
            switch p[1] {
            case 0xFF:
                buckets = []
                return []
            case 0xF0:
                buckets = []
                return nil
            default:
                buckets.append(StepBucket(
                    year: 2000 + QCBand.fromBCD(p[1]), month: QCBand.fromBCD(p[2]), day: QCBand.fromBCD(p[3]),
                    quarter: Int(p[4]),
                    steps: Int(p[9]) | Int(p[10]) << 8,
                    calories: Int(p[7]) | Int(p[8]) << 8,
                    distanceM: Int(p[11]) | Int(p[12]) << 8))
                guard Int(p[5]) >= Int(p[6]) - 1 else { return nil }
                let out = buckets
                buckets = []
                return out
            }
        }
    }

    // MARK: Parsing (big-data channel)

    /// Joins big-data notifications into one reply: `[0xBC][type][len u16 LE][2 bytes][len bytes]`.
    public struct BigDataAssembler: Sendable {
        private var buffer: [UInt8] = []
        public init() {}

        /// Returns the complete reply once `len + 6` bytes have arrived.
        public mutating func feed(_ bytes: [UInt8]) -> [UInt8]? {
            if buffer.isEmpty {
                guard bytes.first == Command.bigData.rawValue else { return nil }
            }
            buffer += bytes
            guard buffer.count >= 4 else { return nil }
            let len = Int(buffer[2]) | Int(buffer[3]) << 8
            guard buffer.count >= len + 6 else { return nil }
            let out = Array(buffer.prefix(len + 6))
            buffer = []
            return out
        }
    }

    public enum SleepStage: UInt8, Sendable {
        case light = 2, deep = 3, rem = 4, awake = 5
    }

    /// One night from the sleep history. Minutes are local minutes of the day the night ends on;
    /// `startMinute > endMinute` means it started the evening before.
    public struct SleepNight: Equatable, Sendable {
        public let daysAgo: Int
        public let startMinute: Int
        public let endMinute: Int
        public let stages: [(stage: UInt8, minutes: Int)]

        public init(daysAgo: Int, startMinute: Int, endMinute: Int, stages: [(stage: UInt8, minutes: Int)]) {
            self.daysAgo = daysAgo; self.startMinute = startMinute; self.endMinute = endMinute
            self.stages = stages
        }

        public static func == (a: SleepNight, b: SleepNight) -> Bool {
            a.daysAgo == b.daysAgo && a.startMinute == b.startMinute && a.endMinute == b.endMinute
                && a.stages.map { $0.stage } == b.stages.map { $0.stage }
                && a.stages.map { $0.minutes } == b.stages.map { $0.minutes }
        }

        /// Total minutes per stage.
        public func minutes(_ stage: SleepStage) -> Int {
            stages.filter { $0.stage == stage.rawValue }.reduce(0) { $0 + $1.minutes }
        }
    }

    /// Sleep reply: `[6]` day count, then per day `[daysAgo][byteCount][start u16][end u16]`
    /// followed by `(byteCount − 4) / 2` `[stage][minutes]` pairs.
    public static func parseSleep(_ r: [UInt8]) -> [SleepNight] {
        guard r.count > 7, r[0] == Command.bigData.rawValue, r[1] == BigDataType.sleep.rawValue else { return [] }
        let days = Int(r[6])
        var i = 7
        var out: [SleepNight] = []
        for _ in 0..<days {
            guard i + 6 <= r.count else { break }
            let daysAgo = Int(r[i]), byteCount = Int(r[i + 1])
            let start = Int(r[i + 2]) | Int(r[i + 3]) << 8
            let end = Int(r[i + 4]) | Int(r[i + 5]) << 8
            i += 6
            var stages: [(stage: UInt8, minutes: Int)] = []
            var j = 4
            while j < byteCount, i + 1 < r.count {
                if r[i + 1] > 0 { stages.append((stage: r[i], minutes: Int(r[i + 1]))) }
                i += 2; j += 2
            }
            out.append(SleepNight(daysAgo: daysAgo, startMinute: start, endMinute: end, stages: stages))
        }
        return out
    }

    /// One hourly SpO2 value (local hour of a day `daysAgo` days back).
    public struct SpO2Hour: Equatable, Sendable {
        public let daysAgo: Int
        public let hour: Int
        public let percent: Int
        public init(daysAgo: Int, hour: Int, percent: Int) {
            self.daysAgo = daysAgo; self.hour = hour; self.percent = percent
        }
    }

    /// SpO2 reply: blocks of `[daysAgo]` + 24 × `[min][max]`, oldest first, ending with today.
    public static func parseSpO2(_ r: [UInt8]) -> [SpO2Hour] {
        guard r.count > 6, r[0] == Command.bigData.rawValue, r[1] == BigDataType.spo2.rawValue else { return [] }
        let end = min(r.count, (Int(r[2]) | Int(r[3]) << 8) + 6)
        var i = 6
        var out: [SpO2Hour] = []
        while i < end {
            let daysAgo = Int(r[i])
            i += 1
            for hour in 0..<24 {
                guard i + 1 < end else { break }
                let lo = Int(r[i]), hi = Int(r[i + 1])
                i += 2
                if lo > 0 && hi > 0 { out.append(SpO2Hour(daysAgo: daysAgo, hour: hour, percent: (lo + hi + 1) / 2)) }
            }
            if daysAgo == 0 { break }
        }
        return out
    }
}
