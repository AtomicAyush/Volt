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
    @Published private(set) var history: [EnergySample] = []
    /// Apps drawing far more than their usual share right now.
    @Published private(set) var callouts: [String] = []

    private var timer: Timer?
    private let queue = DispatchQueue(label: "volt.energy", qos: .utility)
    private var isSampling = false
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
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        timer?.tolerance = 15
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Ranked apps for a window. `.live` is the latest sample; the rest average
    /// every stored sample inside the window so a brief spike cannot dominate.
    func ranked(_ window: EnergyWindow, limit: Int = 8) -> [EnergyEntry] {
        guard let interval = window.interval else { return Array(live.prefix(limit)) }

        let cutoff = Date().addingTimeInterval(-interval)
        let samples = history.filter { $0.date >= cutoff }
        guard !samples.isEmpty else { return Array(live.prefix(limit)) }

        var totals: [String: Double] = [:]
        for sample in samples {
            for (name, impact) in sample.byApp { totals[name, default: 0] += impact }
        }
        let divisor = Double(samples.count)
        return totals
            .map { EnergyEntry(name: $0.key, pid: 0, impact: $0.value / divisor, cpu: 0, icon: icon(for: $0.key)) }
            .sorted { $0.impact > $1.impact }
            .prefix(limit)
            .map { $0 }
    }

    /// A per-app series for the sparklines, bucketed evenly across the window.
    func series(for app: String, window: EnergyWindow, buckets: Int = 24) -> [Double] {
        guard let interval = window.interval else { return [] }
        let now = Date()
        let cutoff = now.addingTimeInterval(-interval)
        let width = interval / Double(buckets)

        var sums = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        for sample in history where sample.date >= cutoff {
            let index = min(buckets - 1, max(0, Int(sample.date.timeIntervalSince(cutoff) / width)))
            sums[index] += sample.byApp[app] ?? 0
            counts[index] += 1
        }
        return zip(sums, counts).map { $1 > 0 ? $0 / Double($1) : 0 }
    }

    // MARK: - Sampling

    func sample() {
        guard !isSampling else { return }
        isSampling = true
        queue.async {
            let rows = Self.readTop()
            DispatchQueue.main.async {
                self.isSampling = false
                guard !rows.isEmpty else { return }
                let entries = self.resolve(rows)
                guard !entries.isEmpty else { return }
                self.live = entries
                self.record(entries)
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
        for row in rows {
            let app = NSRunningApplication(processIdentifier: pid_t(row.pid))
            let name = app?.localizedName ?? Self.normalize(row.command)
            guard !name.isEmpty else { continue }

            if let image = app?.icon, iconCache[name] == nil { iconCache[name] = image }

            if let existing = merged[name] {
                merged[name] = EnergyEntry(name: name, pid: existing.pid,
                                           impact: existing.impact + row.power,
                                           cpu: existing.cpu + row.cpu,
                                           icon: existing.icon)
            } else {
                merged[name] = EnergyEntry(name: name, pid: row.pid, impact: row.power,
                                           cpu: row.cpu, icon: icon(for: name, pid: row.pid))
            }
        }
        return merged.values.sorted { $0.impact > $1.impact }
    }

    /// Two samples are required: `top`'s first pass reports lifetime averages, the
    /// second reports the interval we actually care about.
    private static func readTop() -> [Row] {
        guard let out = Shell.run("/usr/bin/top",
                                  ["-l", "2", "-n", "25", "-o", "cpu",
                                   "-stats", "pid,cpu,power,command"], timeout: 25)
        else { return [] }

        // Keep only the rows after the final header line.
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        guard let headerIndex = lines.lastIndex(where: { $0.contains("PID") && $0.contains("COMMAND") })
        else { return [] }

        var rows: [Row] = []
        for line in lines[(headerIndex + 1)...] {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int(fields[0]),
                  let cpu = Double(fields[1]),
                  let power = Double(fields[2]) else { continue }

            let command = String(fields[3]).trimmingCharacters(in: .whitespaces)
            guard pid != 0, power > 0.1 else { continue }
            // Don't report the sampler Volt just spawned.
            guard command != "top" else { continue }
            rows.append(Row(pid: pid, cpu: cpu, power: power, command: command))
        }
        return rows
    }

    /// "Spotify Helper (Renderer)" and "Google Chrome He" both belong to their parent app.
    private static func normalize(_ raw: String) -> String {
        var name = raw
        if let paren = name.firstIndex(of: "(") { name = String(name[name.startIndex..<paren]) }
        name = name.trimmingCharacters(in: .whitespaces)
        for suffix in [" Helper", " He", " Web Content", " Networking", " GPU", " Renderer"] {
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private func record(_ entries: [EnergyEntry]) {
        var byApp: [String: Double] = [:]
        for entry in entries.prefix(15) { byApp[entry.name] = entry.impact }
        history.append(EnergySample(date: Date(), byApp: byApp))

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
        history = decoded.filter { $0.date >= cutoff }
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
