import Foundation
import AppKit
import Combine

/// One process's share of the battery drain.
struct EnergyEntry: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let pid: Int
    /// Activity Monitor's "Energy Impact" figure.
    let impact: Double
    let cpu: Double
    var icon: NSImage?

    init(name: String, pid: Int, impact: Double, cpu: Double, icon: NSImage? = nil) {
        self.name = name
        self.pid = pid
        self.impact = impact
        self.cpu = cpu
        self.icon = icon
    }

    static func == (a: EnergyEntry, b: EnergyEntry) -> Bool {
        a.name == b.name && a.pid == b.pid && a.impact == b.impact && a.cpu == b.cpu
    }
}

/// A rolled-up energy reading kept on disk so 24h / 7d / 30d history survives relaunches.
struct EnergySample: Codable {
    let date: Date
    /// Process name to energy impact at that moment.
    let byApp: [String: Double]
    /// Process name to CPU use, in percent of one core as Activity Monitor shows it.
    /// Absent from samples recorded before CPU was kept.
    var cpuByApp: [String: Double]?
    /// The whole Mac's CPU use, user plus system, in percent of all cores.
    var systemCPU: Double?
}

/// What the app list ranks by.
enum UsageMetric: String, CaseIterable, Identifiable {
    case energy = "Energy", cpu = "CPU"
    var id: String { rawValue }
}

enum EnergyWindow: String, CaseIterable, Identifiable {
    case live = "Now", day = "24h", week = "7d", month = "30d"
    var id: String { rawValue }

    var interval: TimeInterval? {
        switch self {
        case .live: return nil
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }
}

/// Samples per-process energy impact via `top`, which reports the same figure
/// Activity Monitor shows, and keeps a rolling history on disk.
final class EnergyMonitor: ObservableObject {
    static let shared = EnergyMonitor()

    @Published private(set) var live: [EnergyEntry] = []
    /// The whole Mac's CPU use in the latest sample, in percent of all cores.
    @Published private(set) var systemCPU: Double?
    /// Cores the percentages are out of: 100% per app is one of these fully busy.
    let coreCount = ProcessInfo.processInfo.activeProcessorCount
    @Published private(set) var history: [EnergySample] = []
    /// Apps drawing far more than their usual share right now.
    @Published private(set) var callouts: [String] = []

    private var timer: Timer?
    private let queue = DispatchQueue(label: "volt.energy", qos: .utility)
    private var isSampling = false
    private var recordPending = false
    /// History is written here, off the main thread: the file is a few megabytes.
    private let saveQueue = DispatchQueue(label: "volt.energy.save", qos: .utility)
    private var iconCache: [String: NSImage] = [:]

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Volt", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("energy-history.json")
    }

    private init() { loadHistory() }

    func start(interval: TimeInterval = 120) {
        sample()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        timer?.tolerance = 15
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Ranked apps for a window. `.live` is the latest sample; the rest average
    /// every stored sample inside the window so a brief spike cannot dominate.
    func ranked(_ window: EnergyWindow, by metric: UsageMetric = .energy, limit: Int = 8) -> [EnergyEntry] {
        let liveRanked = metric == .energy ? live.filter { $0.impact > 0.1 } : live.sorted { $0.cpu > $1.cpu }
        guard let interval = window.interval else { return Array(liveRanked.prefix(limit)) }

        let cutoff = Date().addingTimeInterval(-interval)
        // CPU is averaged only over samples that recorded it, so the older history
        // kept before CPU was does not pull every average towards zero.
        let samples = history.filter { $0.date >= cutoff && (metric == .energy || $0.cpuByApp != nil) }
        guard !samples.isEmpty else { return metric == .energy ? Array(liveRanked.prefix(limit)) : [] }

        var totals: [String: Double] = [:]
        for sample in samples {
            for (name, value) in values(in: sample, metric) ?? [:] { totals[name, default: 0] += value }
        }
        let divisor = Double(samples.count)
        return totals
            .map { name, total in
                let average = total / divisor
                return EnergyEntry(name: name, pid: 0,
                                   impact: metric == .energy ? average : 0,
                                   cpu: metric == .cpu ? average : 0,
                                   icon: icon(for: name))
            }
            .sorted { metric == .energy ? $0.impact > $1.impact : $0.cpu > $1.cpu }
            .prefix(limit)
            .map { $0 }
    }

    /// The whole Mac's CPU use: the latest reading, or the average over a window.
    func systemCPU(_ window: EnergyWindow) -> Double? {
        guard let interval = window.interval else { return systemCPU }
        let cutoff = Date().addingTimeInterval(-interval)
        let readings = history.filter { $0.date >= cutoff }.compactMap(\.systemCPU)
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }

    /// When the CPU samples in a window start, if that is well after the window does — CPU
    /// has only been kept since recently — so an average can say what it covers.
    func cpuHistoryStart(_ window: EnergyWindow) -> Date? {
        guard let interval = window.interval else { return nil }
        let cutoff = Date().addingTimeInterval(-interval)
        guard let first = history.first(where: { $0.date >= cutoff && $0.cpuByApp != nil })?.date,
              first.timeIntervalSince(cutoff) > interval * 0.1 else { return nil }
        return first
    }

    private func values(in sample: EnergySample, _ metric: UsageMetric) -> [String: Double]? {
        metric == .energy ? sample.byApp : sample.cpuByApp
    }

    /// A per-app series for the sparklines, bucketed evenly across the window.
    func series(for app: String, window: EnergyWindow, by metric: UsageMetric = .energy,
                buckets: Int = 24) -> [Double] {
        guard let interval = window.interval else { return [] }
        let now = Date()
        let cutoff = now.addingTimeInterval(-interval)
        let width = interval / Double(buckets)

        var sums = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        for sample in history where sample.date >= cutoff {
            guard let values = values(in: sample, metric) else { continue }
            let index = min(buckets - 1, max(0, Int(sample.date.timeIntervalSince(cutoff) / width)))
            sums[index] += values[app] ?? 0
            counts[index] += 1
        }
        let values = zip(sums, counts).map { $1 > 0 ? $0 / Double($1) : 0 }
        // CPU has only been kept since recently: start the line where it starts, rather
        // than drawing the time before as idle.
        if metric == .cpu, let first = counts.firstIndex(where: { $0 > 0 }) {
            return Array(values[first...])
        }
        return values
    }

    // MARK: - Sampling

    /// `record` adds the reading to the history. Only the two-minute timer records, so
    /// the history keeps an even cadence and its averages are not tilted towards the
    /// times the panel happened to be open; the panel's own refreshes pass false. A
    /// recording request that arrives while a reading is under way records that one.
    func sample(record: Bool = true) {
        guard !isSampling else {
            if record { recordPending = true }
            return
        }
        isSampling = true
        recordPending = record
        queue.async {
            let (rows, systemCPU) = Self.readTop()
            DispatchQueue.main.async {
                self.isSampling = false
                let shouldRecord = self.recordPending
                self.recordPending = false
                guard !rows.isEmpty else { return }
                let entries = self.resolve(rows)
                guard !entries.isEmpty else { return }
                self.live = entries
                self.systemCPU = systemCPU
                if shouldRecord { self.record(entries, systemCPU: systemCPU) }
                self.recomputeCallouts()
            }
        }
    }

    /// One row of `top` output, before names are resolved.
    private struct Row {
        let pid: Int
        let cpu: Double
        let power: Double
        let command: String
    }

    /// `top` truncates COMMAND to about fifteen characters, so "Microsoft Outlook"
    /// arrives as "Microsoft Outloo". For anything that is a real running
    /// application the proper name and icon come from the process itself; daemons
    /// keep the name `top` gave them. Names are resolved before merging so the
    /// stored history keys stay stable.
    private func resolve(_ rows: [Row]) -> [EnergyEntry] {
        var merged: [String: EnergyEntry] = [:]
        let running = NSWorkspace.shared.runningApplications
        for row in rows {
            let process = NSRunningApplication(processIdentifier: pid_t(row.pid))
            // A web view's work belongs to the app showing it.
            let app = process.flatMap { Self.host(ofWebKitProcess: $0, among: running) } ?? process
            let name = app?.localizedName ?? Self.normalize(row.command)
            guard !name.isEmpty else { continue }

            if let image = app?.icon, iconCache[name] == nil { iconCache[name] = image }

            if let existing = merged[name] {
                merged[name] = EnergyEntry(name: name, pid: existing.pid,
                                           impact: existing.impact + row.power,
                                           cpu: existing.cpu + row.cpu,
                                           icon: existing.icon)
            } else {
                let pid = app.map { Int($0.processIdentifier) } ?? row.pid
                merged[name] = EnergyEntry(name: name, pid: pid, impact: row.power,
                                           cpu: row.cpu, icon: icon(for: name, pid: pid))
            }
        }
        return merged.values.sorted { $0.impact > $1.impact }
    }

    /// Safari's pages run in WebKit processes of their own — "Safari Web Content",
    /// "Safari Graphics and Media", "Safari Networking" — and so do the web views of
    /// other apps. Their energy is the app's, so they are folded into it. The helper's
    /// name is the app's name plus a translated description, so the app is found by
    /// name, which works in any language. Returns nil for anything else, including a
    /// Safari extension's process ("AdBlock Web Extension"), which keeps its own row.
    private static func host(ofWebKitProcess process: NSRunningApplication,
                             among running: [NSRunningApplication]) -> NSRunningApplication? {
        guard process.bundleIdentifier?.hasPrefix("com.apple.WebKit.") == true,
              let helperName = process.localizedName else { return nil }
        return running
            .filter { app in
                guard app.bundleIdentifier?.hasPrefix("com.apple.WebKit.") != true,
                      let name = app.localizedName, !name.isEmpty else { return false }
                return helperName.hasPrefix(name) || helperName.hasSuffix(name)
            }
            .max { ($0.localizedName?.count ?? 0) < ($1.localizedName?.count ?? 0) }
    }

    /// Two samples are required: `top`'s first pass reports lifetime averages, the
    /// second reports the interval we actually care about.
    /// Also returns the whole Mac's CPU use from the same pass: top's "CPU usage" line,
    /// user plus system.
    private static func readTop() -> (rows: [Row], systemCPU: Double?) {
        guard let out = Shell.run("/usr/bin/top",
                                  ["-l", "2", "-n", "25", "-o", "cpu",
                                   "-stats", "pid,cpu,power,command"], timeout: 25)
        else { return ([], nil) }

        // Keep only the rows after the final header line.
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        guard let headerIndex = lines.lastIndex(where: { $0.contains("PID") && $0.contains("COMMAND") })
        else { return ([], nil) }
        let systemCPU = lines.last(where: { $0.hasPrefix("CPU usage:") }).flatMap(Self.busyPercent)

        var rows: [Row] = []
        for line in lines[(headerIndex + 1)...] {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int(fields[0]),
                  let cpu = Double(fields[1]),
                  let power = Double(fields[2]) else { continue }

            let command = String(fields[3]).trimmingCharacters(in: .whitespaces)
            // kernel_task (pid 0) reports no energy but a good deal of CPU; keep any row
            // that has either.
            guard power > 0.1 || cpu > 0.1 else { continue }
            // Don't report the sampler Volt just spawned.
            guard command != "top" else { continue }
            rows.append(Row(pid: pid, cpu: cpu, power: power, command: command))
        }
        return (rows, systemCPU)
    }

    /// "CPU usage: 21.9% user, 6.80% sys, 72.10% idle" → 27.89.
    ///
    /// top prints each figure as whole and hundredths without zero-padding the second,
    /// so "21.9%" is 21.09 — lines read that way add up to 100, read as decimals they do
    /// not — and the part after the point is taken as hundredths.
    private static func busyPercent(_ line: Substring) -> Double? {
        func value(_ label: String) -> Double? {
            guard let range = line.range(of: "% \(label)"),
                  let number = line[..<range.lowerBound].split(separator: " ").last else { return nil }
            let parts = number.split(separator: ".", maxSplits: 1)
            guard let whole = parts.first.flatMap({ Double($0) }) else { return nil }
            let hundredths = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
            return whole + hundredths / 100
        }
        guard let user = value("user"), let system = value("sys") else { return nil }
        return user + system
    }

    /// "Spotify Helper (Renderer)" and "Google Chrome He" both belong to their parent app.
    private static func normalize(_ raw: String) -> String {
        var name = raw
        if let paren = name.firstIndex(of: "(") { name = String(name[name.startIndex..<paren]) }
        name = name.trimmingCharacters(in: .whitespaces)
        for suffix in [" Helper", " He", " Web Content", " Graphics and Media", " Networking", " GPU", " Renderer"] {
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private func record(_ entries: [EnergyEntry], systemCPU: Double?) {
        var byApp: [String: Double] = [:]
        for entry in entries.prefix(15) where entry.impact > 0.1 { byApp[entry.name] = entry.impact }
        // The fifteen busiest by CPU, which are not always the fifteen by energy.
        var cpuByApp: [String: Double] = [:]
        for entry in entries.sorted(by: { $0.cpu > $1.cpu }).prefix(15) where entry.cpu > 0 {
            cpuByApp[entry.name] = entry.cpu
        }
        history.append(EnergySample(date: Date(), byApp: byApp, cpuByApp: cpuByApp, systemCPU: systemCPU))

        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        history.removeAll { $0.date < cutoff }
        saveHistory()
    }

    /// Flag an app burning more than twice its 24-hour average, and meaningfully so.
    private func recomputeCallouts() {
        let baseline = ranked(.day, limit: 20)
        var flagged: [String] = []
        for entry in live.prefix(6) {
            guard let usual = baseline.first(where: { $0.name == entry.name })?.impact, usual > 1 else { continue }
            if entry.impact > usual * 2, entry.impact > 20 { flagged.append(entry.name) }
        }
        callouts = flagged
    }

    // MARK: - Icons

    private func icon(for name: String, pid: Int = 0) -> NSImage? {
        if let cached = iconCache[name] { return cached }
        var image: NSImage?
        if pid != 0, let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            image = app.icon
        }
        if image == nil {
            image = NSWorkspace.shared.runningApplications
                .first { $0.localizedName == name }?.icon
        }
        if let image { iconCache[name] = image }
        return image
    }

    // MARK: - Persistence

    private func loadHistory() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([EnergySample].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        history = decoded.filter { $0.date >= cutoff }.map(Self.foldingWebKitHelpers)
    }

    /// History recorded before WebKit helpers were folded into their app has them as
    /// rows of their own; fold those the same way, so the app's past and present
    /// figures compare like for like.
    private static func foldingWebKitHelpers(_ sample: EnergySample) -> EnergySample {
        EnergySample(date: sample.date, byApp: folded(sample.byApp),
                     cpuByApp: sample.cpuByApp.map(folded), systemCPU: sample.systemCPU)
    }

    private static func folded(_ values: [String: Double]) -> [String: Double] {
        var byApp: [String: Double] = [:]
        for (name, impact) in values {
            // "Safari Web Content (Cached)" is a Safari helper too.
            var base = name
            if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
                base = String(name[..<open.lowerBound])
            }
            var owner = name
            for suffix in [" Web Content", " Graphics and Media", " Networking"] where base.hasSuffix(suffix) {
                owner = String(base.dropLast(suffix.count))
                break
            }
            if owner.isEmpty { owner = name }
            byApp[owner, default: 0] += impact
        }
        return byApp
    }

    private func saveHistory() {
        let snapshot = history, url = storeURL
        saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
