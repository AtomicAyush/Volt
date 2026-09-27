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
    /// Last case level seen for each pair of AirPods, from macOS's report or the case's
    /// own broadcast, with its own time. The Bluetooth report drops the case now and then
    /// while still giving both pods, so the case is kept apart, put back into a case-less
    /// reading for up to half an hour, and restored from the cache after a relaunch.
    private var lastCase: [String: (percent: Int, seen: Date)] = [:]
    /// When the cache file was last written.
    private var lastSaved = Date.distantPast
    /// Normalised address to the name key of the device the scan listed under it.
    private var scanOwners: [String: String] = [:]
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
        /// When the case level itself was reported; older than `seen` when it was
        /// carried over from an earlier report.
        var caseSeen: Date?
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
            // So a case the first scan after launch leaves out can still be filled in.
            if let box = cells.first(where: { $0.label == "Case" }) {
                lastCase[id] = (box.percent, entry.caseSeen ?? entry.seen)
            }
        }
    }

    private func saveCache() {
        var payload: [String: CachedReading] = [:]
        for (key, reading) in lastKnown {
            let box = reading.cells.first { $0.label == "Case" }
            payload[key] = CachedReading(
                labels: reading.cells.map(\.label),
                percents: reading.cells.map(\.percent),
                seen: reading.seen,
                caseSeen: lastCase[key].flatMap { $0.percent == box?.percent ? $0.seen : nil })
        }
        guard let data = try? JSONEncoder().encode(payload),
              (try? data.write(to: cacheURL, options: .atomic)) != nil else { return }
        lastSaved = Date()
    }

    /// Fills in a device whose current report carries no battery, and records one that
    /// does. Returns nil only when there is nothing useful to show at all.
    private func applyCache(to device: DeviceBattery) -> DeviceBattery? {
        let key = Self.nameKey(device.name)
        if device.hasReading {
            var cells = device.cells
            if let box = cells.first(where: { $0.label == "Case" }) {
                lastCase[key] = (box.percent, Date())
            } else if device.kind == .earbuds, let box = lastCase[key],
                      Date().timeIntervalSince(box.seen) < 1800 {
                // Stored with the case the report just dropped, so a relaunch or a
                // disconnect straight after a case-less scan still has it.
                cells.append(.init(label: "Case", percent: box.percent))
            }
            // The bare LE link AirPods keep for the case carries only the case: it updates
            // `lastCase` above but must not replace a stored reading of the pods.
            if !(device.isBareLELink && device.kind == .earbuds && lastKnown[key] != nil) {
                remember(cells, for: key, seen: Date())
            }
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
            filled.model = device.model
            filled.isRemembered = true
            return filled
        }

        // Nothing remembered. A connected device is still worth listing, with the
        // reason it has no number; a disconnected one with no history is not — unless
        // it has a model number, since it may be broadcasting its level. AirPods Max do,
        // and on macOS 27 that broadcast is the only place their level appears. Such a
        // device stays until Continuity has been consulted, and goes if it is still
        // empty after that.
        guard device.isConnected || device.note != nil else {
            return device.model != nil ? device : nil
        }

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

    /// Records a reading. Broadcasts refresh it every few seconds, so the file is only
    /// rewritten when the levels change, or every five minutes to keep its times current.
    private func remember(_ cells: [DeviceBattery.Cell], for key: String, seen: Date) {
        let previous = lastKnown[key]
        lastKnown[key] = (cells, seen)
        if previous?.cells != cells || Date().timeIntervalSince(lastSaved) > 300 {
            saveCache()
        }
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
        // Tracking can be switched off and on again; subscribe only once.
        if cancellables.isEmpty { subscribe() }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 10
    }

    private func subscribe() {
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
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        queue.async {
            let found = Self.scanBluetooth() + Self.scanAppleHID()
            DispatchQueue.main.async {
                // Tell the decoder which models are paired to this Mac, and their
                // addresses, which a broadcast from this Mac's own AirPods carries.
                BLEBatteryMonitor.shared.pairedModels = Set(found.compactMap(\.model))
                BLEBatteryMonitor.shared.pairedAddressTails = Set(found.compactMap { Self.addressTail($0.id) })
                // Which device each address belongs to, including a second listing that
                // loses to the first in deduplication.
                self.scanOwners = Dictionary(found.map { (BluetoothFrameworkBattery.normalise($0.id), Self.nameKey($0.name)) },
                                             uniquingKeysWith: { first, _ in first })
                // One entry per device before anything is remembered: with AirPods listed
                // twice, the stored reading would otherwise flip between the two.
                self.lastScan = self.deduplicate(found).compactMap { self.applyCache(to: $0) }
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
        // Levels from the Bluetooth framework first. Then a device's own broadcast fills
        // one macOS has nothing live for, replacing a remembered level, and can add a pod
        // or case level a live AirPods report left out; failing that, a case level from
        // the last half hour is put back.
        let framework = BluetoothFrameworkBattery.read()
        let withExact = lastScan.map { applyFramework($0, framework) }
        let withAdvertised = withExact
            .map { device -> DeviceBattery in
                let advertised = applyContinuity(device)
                // A remembered case goes back only onto a report macOS gave live, not onto
                // a broadcast that replaced a remembered reading.
                return device.isRemembered ? advertised : applyRecentCase(advertised)
            }
            // A device kept only in case it was broadcasting, and it was not.
            .filter { $0.hasReading || $0.isConnected || $0.note != nil }
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
        let b = Self.nameKey(device.name)
        // The framework's names are short ("AirPods Pro"), so a name can match more than
        // one device; a record at an address the scan gave to another device is not this one's.
        let byName = framework.first { address, reading in
            let a = Self.nameKey(reading.name)
            return !a.isEmpty && (a == b || b.hasSuffix(a)) && (scanOwners[address] ?? b) == b
        }?.value
        guard let match = byAddress ?? byName else { return device }
        // Off, the framework only holds the level from its last connection, with no age.
        // Volt's own memory, which records the framework's levels while the device is
        // connected (below), covers that with a "last reported" note instead.
        guard match.isConnected else { return device }

        var exact = device
        exact.cells = match.cells
        exact.isConnected = true
        exact.isRemembered = false
        exact.note = nil
        rememberIfComplete(exact, seen: Date())
        return exact
    }

    /// Fills in a device from its own Continuity broadcast where macOS reports nothing
    /// live for it, or adds a pod or case level a live AirPods report left out.
    private func applyContinuity(_ device: DeviceBattery) -> DeviceBattery {
        guard let model = device.model,
              let reading = BLEBatteryMonitor.shared.continuity[model],
              Date().timeIntervalSince(reading.seen) < 300,
              // The broadcast names a model, not a device: with two paired devices of the
              // same model there is no telling whose it is. (One device listed twice, under
              // two addresses, is still one device.)
              Set(lastScan.filter({ $0.model == model }).map { Self.nameKey($0.name) }).count == 1
        else { return device }

        // A level macOS is reporting for a connected device is exact and is never
        // replaced. The report does drop a pod or the case now and then, though, and the
        // broadcast can fill those.
        if device.hasReading && device.isConnected && !device.isRemembered {
            guard device.kind == .earbuds else { return device }
            let have = Set(device.cells.map(\.label))
            let missing = [("L", reading.left), ("R", reading.right), ("Case", reading.casing)]
                .filter { !have.contains($0.0) }
                .compactMap { label, part in part.map { DeviceBattery.Cell(label: label, percent: $0.percent) } }
            guard !missing.isEmpty else { return device }
            if let box = missing.first(where: { $0.label == "Case" }) {
                noteCase(box.percent, seen: reading.seen, for: device)
            }
            var filled = device
            filled.cells = Self.ordered(device.cells + missing)
            rememberIfComplete(filled, seen: Date())
            return filled
        }

        // Otherwise a live broadcast beats nothing, and beats a remembered level, which
        // is minutes to hours old.
        var parts: [(label: String, part: ContinuityReading.Part)] = []
        switch device.kind {
        case .earbuds:
            if let left = reading.left { parts.append(("L", left)) }
            if let right = reading.right { parts.append(("R", right)) }
            if let box = reading.casing { parts.append(("Case", box)) }
        default:
            // Accessory status gives a single battery its own field; proximity pairing
            // puts it where a pod would go.
            if let level = reading.main ?? reading.left ?? reading.right { parts.append(("", level)) }
        }
        guard !parts.isEmpty else { return device }
        if device.kind == .earbuds, let box = reading.casing {
            noteCase(box.percent, seen: reading.seen, for: device)
        }

        var cells = parts.map { DeviceBattery.Cell(label: $0.label, percent: $0.part.percent) }
        // AirPods charging in their case, not connected to this Mac, are still listed in
        // the report with levels macOS keeps current; keep any part the broadcast leaves
        // out. A remembered reading is older than the broadcast, so nothing is kept from it.
        if device.kind == .earbuds, device.hasReading, !device.isRemembered {
            let have = Set(cells.map(\.label))
            cells = Self.ordered(cells + device.cells.filter { !have.contains($0.label) })
        }
        let live = DeviceBattery(id: device.id, name: device.name, kind: device.kind,
                                 cells: cells,
                                 isCharging: parts.contains { $0.part.isCharging },
                                 isConnected: true, note: nil, model: device.model)
        // Kept, so the device still shows its last figure after it stops broadcasting —
        // on macOS 27 nothing else records one for AirPods Max.
        rememberIfComplete(live, seen: reading.seen)
        return live
    }

    /// Records a case level from the case's own broadcast, unless a newer one is known.
    private func noteCase(_ percent: Int, seen: Date, for device: DeviceBattery) {
        let key = Self.nameKey(device.name)
        guard seen > (lastCase[key]?.seen ?? .distantPast) else { return }
        lastCase[key] = (percent, seen)
    }

    /// Records a live reading from somewhere other than the Bluetooth report. AirPods
    /// only when it has both pods and the case: one pod's broadcast must not replace a
    /// stored reading of the whole set.
    private func rememberIfComplete(_ device: DeviceBattery, seen: Date) {
        guard device.hasReading,
              device.kind != .earbuds
                || Set(device.cells.map(\.label)).isSuperset(of: ["L", "R", "Case"]) else { return }
        remember(device.cells, for: Self.nameKey(device.name), seen: seen)
    }

    /// Puts back an AirPods case level the Bluetooth report dropped this time, if one was
    /// reported in the last half hour and nothing live has filled it.
    private func applyRecentCase(_ device: DeviceBattery) -> DeviceBattery {
        guard device.kind == .earbuds, device.hasReading, !device.isRemembered,
              !device.cells.contains(where: { $0.label == "Case" }),
              let box = lastCase[Self.nameKey(device.name)],
              Date().timeIntervalSince(box.seen) < 1800 else { return device }
        var filled = device
        filled.cells.append(.init(label: "Case", percent: box.percent))
        return filled
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
                isCharging: reading.isCharging,
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

    /// The last three bytes of a Bluetooth address such as "68:CA:C4:ED:4D:DC".
    static func addressTail(_ address: String) -> UInt32? {
        let hex = BluetoothFrameworkBattery.normalise(address)
        guard hex.count == 12 else { return nil }
        return UInt32(hex.suffix(6), radix: 16)
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
                var winner = Self.preferred(existing, device)
                let other = winner == existing ? device : existing
                // Two live entries for one device each fill in what the other lacks: macOS
                // also lists AirPods under a bare LE link that carries only the case.
                if winner.isConnected, other.isConnected, !winner.isRemembered, !other.isRemembered {
                    let have = Set(winner.cells.map(\.label))
                    winner.cells = Self.ordered(winner.cells + other.cells.filter { !have.contains($0.label) })
                }
                winner.model = winner.model ?? other.model
                best[key] = winner
            } else {
                best[key] = device
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }

    /// A live level beats a remembered one, which beats an entry that only explains why
    /// there is no number.
    private static func preferred(_ a: DeviceBattery, _ b: DeviceBattery) -> DeviceBattery {
        func rank(_ d: DeviceBattery) -> Int {
            // A bare LE link carrying only the case is not the device's live reading.
            if d.hasReading && d.isConnected && !d.isBareLELink { return 3 }
            if d.hasReading { return 2 }
            if d.isConnected { return 1 }
            return 0
        }
        if rank(a) != rank(b) { return rank(b) > rank(a) ? b : a }
        // Otherwise the fuller entry, and the real one over a bare LE link.
        if a.cells.count != b.cells.count { return b.cells.count > a.cells.count ? b : a }
        return a.isBareLELink && !b.isBareLELink ? b : a
    }

    /// Cells in the order they are drawn: left, right, case.
    private static func ordered(_ cells: [DeviceBattery.Cell]) -> [DeviceBattery.Cell] {
        let order = ["L": 0, "R": 1, "Case": 2]
        return cells.sorted { (order[$0.label] ?? 3) < (order[$1.label] ?? 3) }
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
            case .phone, .tablet:
                // Connected means it is in range and Volt's own link is still being
                // set up, which can take half a minute after launch.
                note = connected ? "Connecting over Bluetooth…" : "Out of Bluetooth range — bring it nearby"
            default: note = nil   // decided later, once the cache has been consulted
            }
        }

        // "0x202D" in the report; kept so Continuity advertisements can be matched. Only
        // for Apple's own accessories — nothing else sends them, and another maker's
        // product ID could collide with a scrambled broadcast's.
        var model: UInt16?
        if (info["device_vendorID"] as? String)?.lowercased() == "0x004c",
           let raw = info["device_productID"] as? String {
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
