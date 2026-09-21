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
    /// The most recent Bluetooth/HID scan, kept so a cable event can be merged in
    /// without waiting for the next (slow) system_profiler run.
    private var lastScan: [DeviceBattery] = []

    private init() {}

    func start(interval: TimeInterval = 60) {
        IOSDeviceMonitor.shared.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.remerge() }
            .store(in: &cancellables)

        BLEBatteryMonitor.shared.$batteries
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
                self.lastScan = found
                self.remerge()
            }
        }
    }

    private func remerge() {
        publish(merge(lastScan,
                      withCabled: IOSDeviceMonitor.shared.devices,
                      andBLE: BLEBatteryMonitor.shared.batteries))
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
    private static func matches(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        return key(a) == key(b)
    }

    private func publish(_ found: [DeviceBattery]) {
        let sorted = found.sorted {
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
            guard [.phone, .tablet, .watch].contains(kind) else { return nil }
            note = kind == .watch
                ? "Battery is not published to this Mac"
                : "Out of Bluetooth range — bring it nearby"
        }

        let address = (info["device_address"] as? String) ?? name
        return DeviceBattery(
            id: address,
            name: name,
            kind: kind,
            cells: cells,
            isCharging: false,
            isConnected: connected,
            note: note
        )
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
