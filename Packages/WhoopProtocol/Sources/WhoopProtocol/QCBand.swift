import Foundation

/// Pure protocol for QC Wireless bands and rings (the hardware behind the "QWatch Pro" / "QRing"
/// apps and the Colmi R0x rings). Platform-pure like `DeviceFamily`: UUIDs are plain strings and
/// the app layer wraps them in `CBUUID(string:)`.
///
/// Every packet in both directions is exactly 16 bytes: `[cmd][14 data bytes][checksum]`, where the
/// checksum is the sum of bytes 0…14 truncated to 8 bits. Command values follow the open-source
/// reverse-engineering in tahnok/colmi_r02_client and Gadgetbridge's Colmi support; they were
/// confirmed on an "H59" band (battery reply `03 64 … 67`, realtime HR reply `69 01 00 …`).
public enum QCBand {

    // MARK: GATT (Nordic-UART-style layout under a 6E40FFF0 service)

    public static let serviceUUIDString = "6e40fff0-b5a3-f393-e0a9-e50e24dcca9e"
    /// App → band (write without response).
    public static let rxCharUUIDString  = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
    /// Band → app (notify).
    public static let txCharUUIDString  = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
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
        case startRealtime      = 0x69
        case stopRealtime       = 0x6A
        /// Unprompted band → app notice; data[1] says what changed (0x01 = new heart-rate data).
        case notification       = 0x73
    }

    /// Reading kinds for START/STOP realtime (data[0]).
    public enum RealtimeKind: UInt8, Sendable {
        case heartRate = 1
        case spo2      = 3
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

    /// SET_TIME: BCD `[yy, MM, dd, HH, mm, ss]` in UTC, then a language byte (1 = English).
    /// The band then logs in UTC, so its history timestamps are plain unix seconds.
    public static func setTime(_ date: Date) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let fields = [(c.year ?? 2000) % 100, c.month ?? 1, c.day ?? 1,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0]
        return packet(.setTime, fields.map(bcd) + [0x01])
    }

    static func bcd(_ v: Int) -> UInt8 { UInt8(((v / 10) << 4) | (v % 10)) }

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

    /// Request the stored heart-rate log for the UTC day starting at `dayStartUnix`.
    public static func readHeartRateLog(dayStartUnix: Int) -> [UInt8] {
        let t = UInt32(clamping: dayStartUnix)
        return packet(.readHeartRateLog,
                      [UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8(t >> 24)])
    }

    /// Unix seconds of the UTC midnight at or before `unix`.
    public static func utcDayStart(_ unix: Int) -> Int { unix - ((unix % 86_400) + 86_400) % 86_400 }

    // MARK: Parsing

    public enum Reply: Equatable, Sendable {
        case battery(percent: Int, charging: Bool)
        /// `bpm == 0` means the band is still measuring (normal for the first few replies).
        case realtime(kind: UInt8, value: Int)
        case realtimeError(kind: UInt8, code: UInt8)
        case notification(kind: UInt8)
        /// One packet of the multi-packet heart-rate log; feed it to `HeartRateLogParser`.
        case heartRateLogPart
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
            return .notification(kind: p[1])
        case .readHeartRateLog:
            return .heartRateLogPart
        default:
            return .other(cmd: p[0])
        }
    }

    /// Reassembles the heart-rate log reply: a header (`sub 0`: packet count, minutes per slot),
    /// then `sub 1` (u32 LE day-start timestamp + 9 slots), then `sub 2…n-1` (13 slots each).
    /// A slot value is bpm, 0 = no reading. `sub 0xFF` means the band has no log for that day.
    public struct HeartRateLogParser: Sendable {
        private var size = 0
        private var minutesPerSlot = 5
        private var dayStart: Int?
        private var slots: [UInt8] = []

        public init() {}

        /// Feed one 0x15 packet. Returns the finished log as `(ts, bpm)` samples (0-bpm slots and
        /// slots after `now` dropped) when the last packet arrives, `[]` for "no data", else nil.
        public mutating func feed(_ p: [UInt8], now: Int) -> [(ts: Int, bpm: Int)]? {
            guard p.count == QCBand.packetLength, p[0] == Command.readHeartRateLog.rawValue else { return nil }
            let sub = Int(p[1])
            switch sub {
            case 0xFF:
                reset()
                return []
            case 0:
                reset()
                size = Int(p[2])
                minutesPerSlot = p[3] == 0 ? 5 : Int(p[3])
                if size <= 1 { return [] }
                return nil
            case 1:
                dayStart = Int(Int32(bitPattern: UInt32(p[2]) | UInt32(p[3]) << 8
                                                 | UInt32(p[4]) << 16 | UInt32(p[5]) << 24))
                slots = Array(p[6..<15])
            default:
                guard dayStart != nil else { return nil }   // missed sub 1 — wait for a fresh log
                slots += p[2..<15]
            }
            guard size > 0, sub >= size - 1, let start = dayStart else { return nil }
            let step = minutesPerSlot * 60
            let samples = slots.enumerated().compactMap { i, bpm -> (ts: Int, bpm: Int)? in
                let ts = start + i * step
                guard bpm > 0, ts <= now else { return nil }
                return (ts: ts, bpm: Int(bpm))
            }
            reset()
            return samples
        }

        private mutating func reset() {
            size = 0; minutesPerSlot = 5; dayStart = nil; slots = []
        }
    }
}
