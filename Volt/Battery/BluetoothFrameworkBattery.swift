import Foundation
import IOBluetooth

/// Exact accessory levels from IOBluetooth — the same figures the Sound menu shows.
///
/// macOS stops putting a level into `system_profiler` once AirPods Max are connected,
/// but the Bluetooth framework still holds it, exact to the percent, behind properties
/// that are not in the public headers (`batteryPercentSingle` and friends). They are
/// read defensively: only when the device answers to the selector, and a zero is taken
/// to mean "not reported" rather than a flat battery.
enum BluetoothFrameworkBattery {
    /// Readings keyed by normalised Bluetooth address, plus the framework's own name
    /// for each device so it can be matched either way.
    struct Reading {
        let name: String
        let cells: [DeviceBattery.Cell]
        /// The framework keeps the last level for devices that are off, so whether the
        /// device is actually connected has to travel with the numbers.
        let isConnected: Bool
    }

    static func read() -> [String: Reading] {
        var result: [String: Reading] = [:]
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] {
            let cells = cells(for: device)
            guard !cells.isEmpty, let address = device.addressString else { continue }
            result[normalise(address)] = Reading(name: device.name ?? "", cells: cells,
                                                 isConnected: device.isConnected())
        }
        return result
    }

    static func normalise(_ address: String) -> String {
        address.lowercased().filter { $0.isHexDigit }
    }

    private static func percent(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let value = device.value(forKey: key) as? Int,
              value > 0, value <= 100 else { return nil }
        return value
    }

    private static func cells(for device: IOBluetoothDevice) -> [DeviceBattery.Cell] {
        var cells: [DeviceBattery.Cell] = []
        if let left = percent(device, "batteryPercentLeft") { cells.append(.init(label: "L", percent: left)) }
        if let right = percent(device, "batteryPercentRight") { cells.append(.init(label: "R", percent: right)) }
        if let single = percent(device, "batteryPercentSingle") { cells.append(.init(label: "", percent: single)) }
        if let box = percent(device, "batteryPercentCase") { cells.append(.init(label: "Case", percent: box)) }
        return cells
    }
}
