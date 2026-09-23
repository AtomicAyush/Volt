import Foundation
import Combine

/// Tracks batteries of connected Bluetooth and Apple HID accessories.
///
/// `system_profiler SPBluetoothDataType` is the only public source that reports
/// AirPods left/right/case levels, so it is polled on a background queue.
final class DeviceMonitor: ObservableObject {
    static let shared = DeviceMonitor()

    @Published private(set) var devices: [DeviceBattery] = []

    /// Previous and current list, so the alert engine can spot downward crossings.
    let transitions = PassthroughSubject<(old: [DeviceBattery], new: [DeviceBattery]), Never>()

    private var timer: Timer?
    private let queue = DispatchQueue(label: "volt.devices", qos: .utility)
    private var isRefreshing = false
    private var cancellables = Set<AnyCancellable>()

    /// Last battery reading seen for each device, so a device that stops reporting
    /// still shows a number. macOS drops the battery keys for some accessories once
    /// they are actually connected — AirPods Max report a level while disconnected and
    /// nothing at all once in use — and hiding them at that point is the worst answer.
    private var lastKnown: [String: (cells: [DeviceBattery.Cell], seen: Date)] = [:]
    /// The most recent Bluetooth/HID scan, kept so a cable event can be merged in
    /// without waiting for the next (slow) system_profiler run.
    private var lastScan: [DeviceBattery] = []

    private init() { loadCache() }

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Volt", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("device-levels.json")
    }

    private struct CachedReading: Codable {
        var labels: [String]
        var percents: [Int]
        var seen: Date
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CachedReading].self, from: data)
        else { return }
        for (id, entry) in decoded {
            let cells = zip(entry.labels, entry.percents).map {
                DeviceBattery.Cell(label: $0, percent: $1)
            }
            lastKnown[id] = (cells, entry.seen)
        }
    }

    private func saveCache() {
        let payload = lastKnown.mapValues {
            CachedReading(labels: $0.cells.map(\.label),
                          percents: $0.cells.map(\.percent),
                          seen: $0.seen)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Fills in a device whose current report carries no battery, and records one that
    /// does. Returns nil only when there is nothing useful to show at all.
    private func applyCache(to device: DeviceBattery) -> DeviceBattery? {
        let key = Self.nameKey(device.name)
        if device.hasReading {
            lastKnown[key] = (device.cells, Date())
            saveCache()
            return device
        }

        // Beyond half a day the remembered level says nothing useful — AirPods left in
        // a case read 1% a day later — so the device is listed without a number instead.
        if let remembered = lastKnown[key],
           Date().timeIntervalSince(remembered.seen) < 12 * 3600 {
            var filled = device
            filled = DeviceBattery(id: device.id, name: device.name, kind: device.kind,
                                   cells: remembered.cells, isCharging: false,
                                   isConnected: false,
                                   note: Self.ageNote(since: remembered.seen))
            return filled
        }

        // Nothing remembered. A connected device is still worth listing, with the
        // reason it has no number; a disconnected one with no history is not.
        guard device.isConnected || device.note != nil else { return nil }

        // A bare LE link with no battery and no history says nothing about the device
        // being in use — headphones sitting in a drawer can hold one — so it is left
        // out. Phones, tablets and watches are the exception: their note explains
        // the missing number and they are expected in the list.
        if device.isBareLELink, ![.phone, .tablet, .watch].contains(device.kind) {
            return nil
        }
        var plain = device
        if plain.note == nil { plain.note = "Battery not reported over Bluetooth" }
        return plain
    }

    private static func ageNote(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<120: return "Last reported just now"
        case ..<3600: return "Last reported \(seconds / 60) min ago"
        case ..<86400: return "Last reported \(seconds / 3600) h ago"
        default: return "Last reported \(seconds / 86400) d ago"
        }
    }

    func start(interval: TimeInterval = 60) {
        IOSDeviceMonitor.shared.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.remerge() }
            .store(in: &cancellables)

        BLEBatteryMonitor.shared.$batteries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.remerge() }
            .store(in: &cancellables)

        BLEBatteryMonitor.shared.$continuity
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.remerge() }
            .store(in: &cancellables)

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 10
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        queue.async {
            let found = Self.scanBluetooth() + Self.scanAppleHID()
            DispatchQueue.main.async {
                // Tell the decoder which models belong to this Mac, so a neighbour's
                // AirPods of the same kind are never mistaken for the user's.
                BLEBatteryMonitor.shared.pairedModels = Set(found.compactMap(\.model))
                self.lastScan = found.compactMap { self.applyCache(to: $0) }
                self.remerge()
            }
        }
    }

    /// Hides a device from the list for good, until it is shown again from Settings.
    func hide(_ device: DeviceBattery) {
        Preferences.shared.hiddenDevices.insert(Self.nameKey(device.name))
        Preferences.shared.hiddenDeviceNames[Self.nameKey(device.name)] = device.name
        remerge()
    }

    func unhide(key: String) {
        Preferences.shared.hiddenDevices.remove(key)
        Preferences.shared.hiddenDeviceNames.removeValue(forKey: key)
        remerge()
    }

    private func remerge() {
        // Exact levels from the Bluetooth framework first; the rounded broadcast decode
        // only fills whatever is still empty after that.
        let framework = BluetoothFrameworkBattery.read()
        let withExact = lastScan.map { applyFramework($0, framework) }
        let withAdvertised = withExact.map(applyContinuity)
        publish(merge(withAdvertised,
                      withCabled: IOSDeviceMonitor.shared.devices,
                      andBLE: BLEBatteryMonitor.shared.batteries))
    }

    /// Fills in a device from IOBluetooth, matching on address first and, since the
    /// framework and the report can name the same device differently ("AirPods Max"
    /// against "Ayush's AirPods Max"), on name as a fallback.
    private func applyFramework(_ device: DeviceBattery,
                                _ framework: [String: BluetoothFrameworkBattery.Reading]) -> DeviceBattery {
        guard !device.hasReading || !device.isConnected else { return device }

        let byAddress = framework[BluetoothFrameworkBattery.normalise(device.id)]
        let byName = framework.values.first {
            let a = Self.nameKey($0.name), b = Self.nameKey(device.name)
            return !a.isEmpty && (a == b || b.hasSuffix(a))
        }
        guard let match = byAddress ?? byName else { return device }

        var exact = device
        exact.cells = match.cells
        exact.isApproximate = false
        exact.isConnected = match.isConnected
        // A connected device's figure is current; an off one keeps its "last reported"
        // note so the number is not mistaken for live.
        if match.isConnected { exact.note = nil }
        return exact
    }

    /// Fills in a device from its own Continuity broadcast. Only used where macOS
    /// reports nothing — an exact level always wins over a rounded one.
    private func applyContinuity(_ device: DeviceBattery) -> DeviceBattery {
        // Only ever fills a gap. A level macOS reports is exact and complete; a
        // decoded one is rounded to ten and can be missing a pod, so it must not
        // replace one.
        guard !device.hasReading,
              let model = device.model,
              let reading = BLEBatteryMonitor.shared.continuity[model],
              Date().timeIntervalSince(reading.seen) < 300 else { return device }

        var cells: [DeviceBattery.Cell] = []
        switch device.kind {
        case .earbuds:
            if let left = reading.primary { cells.append(.init(label: "L", percent: left)) }
            if let right = reading.secondary { cells.append(.init(label: "R", percent: right)) }
            if let box = reading.caseLevel { cells.append(.init(label: "Case", percent: box)) }
        default:
            // A single unit reports in one of the two pod nibbles. The case nibble is
            // deliberately ignored here: headphones have no case, and that field reads
            // as a constant for devices that lack one.
            if let level = reading.primary ?? reading.secondary {
                cells.append(.init(label: "", percent: level))
            }
        }
        guard !cells.isEmpty else { return device }

        return DeviceBattery(id: device.id, name: device.name, kind: device.kind,
                             cells: cells, isCharging: reading.isCharging, isConnected: true,
                             note: nil, model: device.model, isApproximate: true)
    }

    /// A real reading replaces the placeholder for the same device. Names differ
    /// only in capitalisation and apostrophe style across sources, so match loosely.
    private func merge(_ bluetooth: [DeviceBattery],
                       withCabled cabled: [IOSDevice],
                       andBLE ble: [BLEBattery]) -> [DeviceBattery] {
        var result = bluetooth

        // Bluetooth first: the live percentage for a nearby iPhone or iPad.
        for reading in ble {
            let entry = DeviceBattery(
                id: reading.id.uuidString,
                name: reading.name,
                kind: .from(minorType: nil, name: reading.name),
                cells: [.init(label: "", percent: reading.percent)],
                isCharging: false,
                isConnected: !reading.isStale,
                note: nil
            )
            if let index = result.firstIndex(where: {
                Self.matches($0.name, reading.name) && !$0.hasReading
            }) {
                result[index] = entry
            } else if !result.contains(where: { Self.matches($0.name, reading.name) }) {
                result.append(entry)
            }
        }

        // Then the cable, which also carries the charging state.
        for device in cabled {
            let entry = DeviceBattery(
                id: device.udid,
                name: device.name,
                kind: device.kind,
                cells: [.init(label: "", percent: device.percent)],
                isCharging: device.isCharging,
                isConnected: true,
                note: nil
            )
            if let index = result.firstIndex(where: { Self.matches($0.name, device.name) }) {
                result[index] = entry
            } else {
                result.append(entry)
            }
        }
        return result
    }

    /// "Ayush's Iphone" from Bluetooth and "Ayush's iPhone" from the cable are the
    /// same device; compare on letters and digits only.
    static func nameKey(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func matches(_ a: String, _ b: String) -> Bool {
        nameKey(a) == nameKey(b)
    }

    /// Collapses entries for the same device.
    ///
    /// macOS lists a connected accessory under a rotating private address and the same
    /// accessory under its real one, so AirPods can arrive twice — once with a level
    /// and once without. Names are the only thing stable across both.
    private func deduplicate(_ devices: [DeviceBattery]) -> [DeviceBattery] {
        var best: [String: DeviceBattery] = [:]
        var order: [String] = []

        for device in devices {
            let key = Self.nameKey(device.name)
            if let existing = best[key] {
                best[key] = Self.preferred(existing, device)
            } else {
                best[key] = device
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }

    /// An exact live level beats a rounded one, which beats a remembered one, which
    /// beats an entry that only explains why there is no number.
    private static func preferred(_ a: DeviceBattery, _ b: DeviceBattery) -> DeviceBattery {
        func rank(_ d: DeviceBattery) -> Int {
            if d.hasReading && !d.isApproximate && d.isConnected { return 5 }
            if d.hasReading && !d.isApproximate { return 4 }
            if d.hasReading && d.isConnected { return 3 }
            if d.hasReading { return 2 }
            if d.isConnected { return 1 }
            return 0
        }
        return rank(b) > rank(a) ? b : a
    }

    private func publish(_ found: [DeviceBattery]) {
        let hidden = Preferences.shared.hiddenDevices
        let visible = deduplicate(found).filter { !hidden.contains(Self.nameKey($0.name)) }
        let sorted = visible.sorted {
            // Devices with a real reading first, then connected, then by level.
            if $0.hasReading != $1.hasReading { return $0.hasReading }
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            return $0.lowestPercent < $1.lowestPercent
        }
        self.isRefreshing = false
        guard sorted != devices else { return }
        let old = devices
        devices = sorted
        transitions.send((old: old, new: sorted))
    }

    // MARK: - Sources

    private static func scanBluetooth() -> [DeviceBattery] {
        guard let json = Shell.run("/usr/sbin/system_profiler",
                                   ["SPBluetoothDataType", "-json"], timeout: 25),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var result: [DeviceBattery] = []
        for section in sections {
            for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
                guard let entries = section[key] as? [[String: Any]] else { continue }
                for entry in entries {
                    for (name, value) in entry {
                        guard let info = value as? [String: Any] else { continue }
                        if let device = parse(name: name, info: info, connected: connected) {
                            result.append(device)
                        }
                    }
                }
            }
        }
        return result
    }

    private static func parse(name: String, info: [String: Any], connected: Bool) -> DeviceBattery? {
        func percent(_ key: String) -> Int? {
            guard let raw = info[key] as? String else { return nil }
            return Int(raw.filter(\.isNumber))
        }

        var cells: [DeviceBattery.Cell] = []
        if let left = percent("device_batteryLevelLeft") { cells.append(.init(label: "L", percent: left)) }
        if let right = percent("device_batteryLevelRight") { cells.append(.init(label: "R", percent: right)) }
        if let single = percent("device_batteryLevelMain") ?? percent("device_batteryLevelSingle") {
            cells.append(.init(label: "", percent: single))
        }
        if let kase = percent("device_batteryLevelCase") { cells.append(.init(label: "Case", percent: kase)) }

        let kind = DeviceBattery.Kind.from(minorType: info["device_minorType"] as? String, name: name)

        // An iPhone, iPad or Watch is worth listing even with no level: Bluetooth
        // never carries one, so say where the number would come from instead of
        // hiding the device.
        var note: String?
        if cells.isEmpty {
            switch kind {
            case .watch: note = "Battery is not published to this Mac"
            case .phone, .tablet: note = "Out of Bluetooth range — bring it nearby"
            default: note = nil   // decided later, once the cache has been consulted
            }
        }

        // "0x202D" in the report; kept so Continuity advertisements can be matched.
        var model: UInt16?
        if let raw = info["device_productID"] as? String {
            let digits = raw.hasPrefix("0x") ? String(raw.dropFirst(2)) : raw
            model = UInt16(digits, radix: 16)
        }

        // "0x400000 < BLE >" means a bare LE link; real use adds audio or HID profiles.
        let services = (info["device_services"] as? String) ?? ""
        let bareLE = services.contains("BLE") && !services.contains("A2DP")
            && !services.contains("HFP") && !services.contains("HID")

        let address = (info["device_address"] as? String) ?? name
        var device = DeviceBattery(
            id: address,
            name: name,
            kind: kind,
            cells: cells,
            isCharging: false,
            isConnected: connected,
            note: note,
            model: model
        )
        device.isBareLELink = bareLE
        return device
    }

    /// Magic Mouse / Keyboard / Trackpad publish `BatteryPercent` straight into the registry.
    private static func scanAppleHID() -> [DeviceBattery] {
        guard let text = Shell.run("/usr/sbin/ioreg", ["-r", "-l", "-k", "BatteryPercent"], timeout: 10)
        else { return [] }

        var result: [DeviceBattery] = []
        var product: String?
        var percent: Int?
        var serial: String?

        func flush() {
            if let product, let percent {
                result.append(DeviceBattery(
                    id: serial ?? product,
                    name: product,
                    kind: .from(minorType: nil, name: product),
                    cells: [.init(label: "", percent: percent)],
                    isCharging: false,
                    isConnected: true,
                    note: nil
                ))
            }
            product = nil; percent = nil; serial = nil
        }

        for line in text.split(separator: "\n") {
            if line.contains("+-o") { flush(); continue }
            if let value = capture(line, key: "Product") { product = value }
            if let value = capture(line, key: "SerialNumber") { serial = value }
            if line.contains("\"BatteryPercent\""),
               let n = line.split(separator: "=").last.map({ $0.filter(\.isNumber) }), let v = Int(n) {
                percent = v
            }
        }
        flush()
        return result
    }

    private static func capture(_ line: Substring, key: String) -> String? {
        guard line.contains("\"\(key)\"") else { return nil }
        let parts = line.components(separatedBy: "=")
        guard parts.count >= 2 else { return nil }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("\"") else { return nil }
        return String(value.dropFirst().dropLast())
    }
}
