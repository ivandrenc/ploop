import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// Drives one connection to a QC Wireless band (QWatch Pro / Colmi protocol, see `QCBand`):
/// sets its clock, keeps realtime HR alive, and pulls its stored history one request at a time
/// (the band answers one history request at a time).
///
/// Where the data lands:
/// - heart rate → `hrSample` under the strap device id (same as WHOOP HR, so strain etc. use it)
/// - sleep nights → `sleepSession` + `dailyMetric` under `bandDeviceId`, with the night's
///   band HRV, SpO2 and resting HR folded in
/// - steps / HRV / SpO2 / sleep → daily metric series under `bandDeviceId`
@MainActor
final class QCBandSession {
    /// Source id for band-derived nightly rows and series. Repository merges it between the
    /// on-device computed scores and any WHOOP import.
    static let bandDeviceId = Repository.bandDeviceId
    /// Days of history pulled on connect.
    static let initialSyncDays = 7
    /// A history request with no reply for this long is abandoned.
    static let jobTimeoutSeconds = 20.0

    enum Job: Equatable {
        case heartRate(daysAgo: Int)
        case steps(daysAgo: Int)
        case hrv(daysAgo: Int)
        case spo2
        case sleep
    }

    private let state: LiveState
    private let deviceId: String
    private let write: ([UInt8]) -> Void
    private let writeBigData: ([UInt8]) -> Void
    private let log: (String) -> Void
    private let collector: () -> Collector?
    private let store: () -> WhoopStore?
    /// Fired after a full history pass so the app can rescore and refresh the dashboard.
    var onHistorySynced: (() -> Void)?

    private var jobs: [Job] = []
    private var current: Job?
    private var jobTimeout: DispatchWorkItem?
    private var hrParser = QCBand.SlotLogParser(kind: .heartRate)
    private var hrvParser = QCBand.SlotLogParser(kind: .hrv)
    private var stepsParser = QCBand.StepsParser()
    private var bigData = QCBand.BigDataAssembler()
    private var tick = 0
    private var started = false

    /// Collected during a sync pass, folded into each night when the sleep reply arrives.
    private var hrvSamples: [Int: Int] = [:]     // unix ts → ms
    private var spo2Samples: [Int: Int] = [:]    // unix ts (hour start) → %

    init(state: LiveState, deviceId: String,
         write: @escaping ([UInt8]) -> Void, writeBigData: @escaping ([UInt8]) -> Void,
         log: @escaping (String) -> Void,
         collector: @escaping () -> Collector?, store: @escaping () -> WhoopStore?) {
        self.state = state; self.deviceId = deviceId
        self.write = write; self.writeBigData = writeBigData; self.log = log
        self.collector = collector; self.store = store
    }

    // MARK: Lifecycle

    /// Run once the band's notifications are on: clock, battery, enable its own logging, then
    /// pull the last week of history.
    func start(realtime: Bool) {
        guard !started else { return }
        started = true
        log("QC band ready — syncing clock and history")
        write(QCBand.setTime(Date()))
        write(QCBand.batteryRequest())
        write(QCBand.enableHeartRateLog(intervalMinutes: 5))
        write(QCBand.enableSpO2Log())
        write(QCBand.enableHRVLog())
        if realtime { write(QCBand.startRealtime()) }
        sync(days: Self.initialSyncDays)
    }

    func stop() {
        jobTimeout?.cancel()
        jobTimeout = nil
        jobs.removeAll()
        current = nil
    }

    /// Every keep-alive tick (30 s): battery (its reply also feeds the liveness watchdog), keep a
    /// realtime session alive, and re-pull today's history every ~15 min.
    func keepAlive(realtime: Bool, ticksPerSync: Int) {
        tick += 1
        write(QCBand.batteryRequest())
        if realtime { write(QCBand.continueRealtime()) }
        if tick % max(1, ticksPerSync) == 0 { sync(days: 1) }
    }

    func setRealtime(_ on: Bool) {
        write(on ? QCBand.startRealtime() : QCBand.stopRealtime())
    }

    // MARK: Job queue

    /// Queue a history pass covering the last `days` days (today included).
    func sync(days: Int) {
        var add: [Job] = []
        for d in (0..<days).reversed() { add.append(.heartRate(daysAgo: d)) }
        for d in (0..<days).reversed() { add.append(.steps(daysAgo: d)) }
        for d in (0..<days).reversed() { add.append(.hrv(daysAgo: d)) }
        add += [.spo2, .sleep]   // big-data replies cover every stored day; sleep last (uses HRV/SpO2)
        for j in add where j != current && !jobs.contains(j) { jobs.append(j) }
        if current == nil { next() }
    }

    private func next() {
        jobTimeout?.cancel()
        guard !jobs.isEmpty else {
            current = nil
            return
        }
        let job = jobs.removeFirst()
        current = job
        let now = Date()
        switch job {
        case .heartRate(let d):
            hrParser = QCBand.SlotLogParser(kind: .heartRate)
            let dayStart = QCBand.localDayStart(daysAgo: d, now: now)
            write(QCBand.readHeartRateLog(bandDayStart: QCBand.bandSeconds(dayStart)))
        case .steps(let d):
            stepsParser = QCBand.StepsParser()
            write(QCBand.readSteps(daysAgo: d))
        case .hrv(let d):
            hrvParser = QCBand.SlotLogParser(kind: .hrv)
            write(QCBand.readHRVLog(daysAgo: d))
        case .spo2:
            bigData = QCBand.BigDataAssembler()
            writeBigData(QCBand.bigDataRequest(.spo2))
        case .sleep:
            bigData = QCBand.BigDataAssembler()
            writeBigData(QCBand.bigDataRequest(.sleep))
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.current == job else { return }
            self.log("QC: no reply to \(job) — skipping")
            self.finish(job)
        }
        jobTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.jobTimeoutSeconds, execute: item)
    }

    private func finish(_ job: Job) {
        guard current == job else { return }
        if job == .sleep {
            state.lastSyncedAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(state.lastSyncedAt, forKey: "lastSyncedAt")
            onHistorySynced?()
        }
        next()
    }

    // MARK: Incoming

    /// Command-channel notification.
    func handle(_ bytes: [UInt8]) {
        guard let reply = QCBand.parse(bytes) else {
            log("QC: unparsed \(hex(bytes))")
            return
        }
        let now = Date()
        switch reply {
        case let .battery(pct, _):
            state.setBattery(Double(pct))
        case let .realtime(kind, bpm) where kind == QCBand.RealtimeKind.heartRate.rawValue:
            guard bpm > 0 else { return }   // 0 = still measuring
            if bpm >= 30 && bpm <= 220 { state.heartRate = bpm }
            collector()?.ingestStandardHR(hr: bpm, rr: [], at: Int(now.timeIntervalSince1970))
        case let .realtimeError(kind, code):
            log("QC: realtime kind \(kind) error \(code) (band not worn snugly?)")
        case let .notification(kind, data):
            switch QCBand.NotificationKind(rawValue: kind) {
            case .some(.newHeartRate):
                sync(days: 1)
            case .some(.battery):
                state.setBattery(Double(data[0]))
            default:
                break
            }
        case .heartRateLogPart:
            guard case .heartRate(let d)? = current, let samples = hrParser.feed(bytes) else { return }
            let dayStart = QCBand.localDayStart(daysAgo: d, now: now)
            let nowTs = Int(now.timeIntervalSince1970)
            var n = 0
            for s in samples {
                let ts = dayStart + s.minuteOfDay * 60
                guard ts <= nowTs else { continue }
                collector()?.ingestStandardHR(hr: s.value, rr: [], at: ts)
                n += 1
            }
            if let c = collector() { Task { @MainActor in await c.flushStandardHR() } }
            log("QC: heart rate \(d)d ago — \(n) samples")
            finish(.heartRate(daysAgo: d))
        case .hrvLogPart:
            guard case .hrv(let d)? = current, let samples = hrvParser.feed(bytes) else { return }
            let dayStart = QCBand.localDayStart(daysAgo: d, now: now)
            for s in samples { hrvSamples[dayStart + s.minuteOfDay * 60] = s.value }
            persistDailySeries(key: "hrv", samples: samples.map { (dayStart + $0.minuteOfDay * 60, Double($0.value)) })
            log("QC: HRV \(d)d ago — \(samples.count) samples")
            finish(.hrv(daysAgo: d))
        case .stepsPart:
            guard case .steps(let d)? = current, let buckets = stepsParser.feed(bytes) else { return }
            persistSteps(buckets)
            log("QC: steps \(d)d ago — \(buckets.reduce(0) { $0 + $1.steps }) steps")
            finish(.steps(daysAgo: d))
        default:
            break
        }
    }

    /// Big-data-channel notification (sleep / SpO2 history).
    func handleBigData(_ bytes: [UInt8]) {
        guard let reply = bigData.feed(bytes) else { return }
        let now = Date()
        switch reply[1] {
        case QCBand.BigDataType.spo2.rawValue:
            let hours = QCBand.parseSpO2(reply)
            for h in hours {
                let ts = QCBand.localDayStart(daysAgo: h.daysAgo, now: now) + h.hour * 3_600
                spo2Samples[ts] = h.percent
            }
            persistDailySeries(key: "spo2", samples: spo2Samples.map { ($0.key, Double($0.value)) })
            log("QC: SpO2 — \(hours.count) hourly values")
            finish(.spo2)
        case QCBand.BigDataType.sleep.rawValue:
            let nights = QCBand.parseSleep(reply)
            log("QC: sleep — \(nights.count) nights")
            let hrv = hrvSamples, spo2 = spo2Samples
            Task { @MainActor in
                await self.persistSleep(nights, now: now, hrv: hrv, spo2: spo2)
                self.finish(.sleep)
            }
        default:
            log("QC: unknown big-data reply \(hex(Array(reply.prefix(8))))")
        }
    }

    // MARK: Persistence

    private func persistSteps(_ buckets: [QCBand.StepBucket]) {
        guard let store = store(), !buckets.isEmpty else { return }
        var byDay: [String: Int] = [:]
        for b in buckets { byDay[b.dayString, default: 0] += b.steps }
        let rows = byDay.map { MetricPoint(day: $0.key, key: "steps", value: Double($0.value)) }
        Task { _ = try? await store.upsertMetricSeries(rows, deviceId: Self.bandDeviceId) }
    }

    /// Daily mean of timestamped values as a metric series (keyed by local day).
    private func persistDailySeries(key: String, samples: [(Int, Double)]) {
        guard let store = store(), !samples.isEmpty else { return }
        var byDay: [String: [Double]] = [:]
        for (ts, v) in samples { byDay[Self.localDayString(ts), default: []].append(v) }
        let rows = byDay.map { MetricPoint(day: $0.key, key: key, value: $0.value.reduce(0, +) / Double($0.value.count)) }
        Task { _ = try? await store.upsertMetricSeries(rows, deviceId: Self.bandDeviceId) }
    }

    private func persistSleep(_ nights: [QCBand.SleepNight], now: Date,
                              hrv: [Int: Int], spo2: [Int: Int]) async {
        guard let store = store(), !nights.isEmpty else { return }
        var sessions: [CachedSleepSession] = []
        var dailies: [DailyMetric] = []
        var series: [MetricPoint] = []
        for n in nights {
            let dayStart = QCBand.localDayStart(daysAgo: n.daysAgo, now: now)
            let startMin = n.startMinute > n.endMinute ? n.startMinute - 1_440 : n.startMinute
            let start = dayStart + startMin * 60
            let end = dayStart + n.endMinute * 60
            guard end > start else { continue }

            let light = Double(n.minutes(.light)), deep = Double(n.minutes(.deep))
            let rem = Double(n.minutes(.rem)), awake = Double(n.minutes(.awake))
            let asleep = light + deep + rem
            guard asleep > 0 else { continue }
            let inBed = max(asleep + awake, Double(end - start) / 60)
            let efficiency = min(1, asleep / inBed)
            let disturbances = n.stages.filter { $0.stage == QCBand.SleepStage.awake.rawValue }.count

            let nightHRV = hrv.filter { $0.key >= start && $0.key <= end }.map { Double($0.value) }
            let avgHrv = nightHRV.isEmpty ? nil : nightHRV.reduce(0, +) / Double(nightHRV.count)
            let nightSpO2 = spo2.filter { $0.key >= start - 3_600 && $0.key <= end }.map { Double($0.value) }
            let spo2Pct = nightSpO2.isEmpty ? nil : nightSpO2.reduce(0, +) / Double(nightSpO2.count)
            let hr = (try? await store.hrSamples(deviceId: deviceId, from: start, to: end, limit: 5_000)) ?? []
            let restingHr = Self.restingHR(hr.map(\.bpm))

            let stages: [String: Double] = ["light": light, "deep": deep, "rem": rem, "awake": awake]
            let json = (try? JSONSerialization.data(withJSONObject: stages)).flatMap { String(data: $0, encoding: .utf8) }
            sessions.append(CachedSleepSession(startTs: start, endTs: end, efficiency: efficiency,
                                               restingHr: restingHr, avgHrv: avgHrv, stagesJSON: json))
            // Keyed like the on-device engine (UTC day of wake) so Repository merges per day.
            let day = AnalyticsEngine.dayString(end)
            dailies.append(DailyMetric(day: day, totalSleepMin: asleep, efficiency: efficiency,
                                       deepMin: deep, remMin: rem, lightMin: light,
                                       disturbances: disturbances, restingHr: restingHr, avgHrv: avgHrv,
                                       recovery: nil, strain: nil, exerciseCount: nil, spo2Pct: spo2Pct))
            func add(_ key: String, _ v: Double?) {
                if let v { series.append(MetricPoint(day: day, key: key, value: v)) }
            }
            add("sleep_total_min", asleep); add("sleep_deep_min", deep); add("sleep_rem_min", rem)
            add("sleep_light_min", light); add("awake_min", awake); add("sleep_efficiency", efficiency * 100)
            add("rhr", restingHr.map(Double.init))
        }
        _ = try? await store.upsertSleepSessions(sessions, deviceId: Self.bandDeviceId)
        _ = try? await store.upsertDailyMetrics(dailies, deviceId: Self.bandDeviceId)
        _ = try? await store.upsertMetricSeries(series, deviceId: Self.bandDeviceId)
    }

    /// Resting HR for a night: the 10th-percentile sleeping heart rate (robust to stray lows).
    static func restingHR(_ bpm: [Int]) -> Int? {
        let v = bpm.filter { $0 >= 30 && $0 <= 220 }.sorted()
        guard v.count >= 3 else { return nil }
        return v[v.count / 10]
    }

    private static let localDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func localDayString(_ ts: Int) -> String {
        localDay.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
