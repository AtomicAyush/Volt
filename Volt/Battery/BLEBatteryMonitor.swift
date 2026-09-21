import Foundation
import CoreBluetooth
import Combine

/// A battery level read over Bluetooth Low Energy.
struct BLEBattery: Identifiable, Equatable {
    let id: UUID
    let name: String
    let percent: Int
    let updated: Date
    /// True once the device has dropped its connection. The last level is kept rather
    /// than discarded: a phone flits in and out of range constantly, and blanking the
    /// reading each time would make the panel flicker between a number and an excuse.
    var isStale: Bool = false
}

/// Reads iPhone and iPad battery over Bluetooth, with no cable.
///
/// An iPhone or iPad that is BLE-connected to the Mac exposes the standard GATT
/// Battery Service (0x180F) with the Battery Level characteristic (0x2A19). That is
/// a plain, public Bluetooth profile — nothing Apple-specific — so a normal
/// `CBCentralManager` can read it.
///
/// This is a separate path from `IOSDeviceMonitor`: Bluetooth gives the live
/// percentage, while health, cycle count and lifetime stats still need the cable.
/// `system_profiler` never reports a level for these devices, which is why the
/// characteristic has to be read directly.
final class BLEBatteryMonitor: NSObject, ObservableObject {
    static let shared = BLEBatteryMonitor()

    @Published private(set) var batteries: [BLEBattery] = []
    /// Reflects Bluetooth availability and permission, for the settings screen.
    @Published private(set) var state: CBManagerState = .unknown

    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    private var central: CBCentralManager?
    /// CoreBluetooth does not retain peripherals; dropping one cancels its connection.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var levels: [UUID: BLEBattery] = [:]
    private var timer: Timer?

    /// Peripherals that have answered with a battery level before. CoreBluetooth
    /// identifiers are stable per Mac, so remembering them lets Volt reconnect
    /// without having to rediscover the device by scanning.
    private var knownIdentifiers: Set<UUID> = []

    /// Strongest Continuity reading seen for each model, keyed by model number.
    private var continuityByModel: [UInt16: ContinuityReading] = [:]

    /// Model numbers of devices actually paired to this Mac, supplied by DeviceMonitor.
    /// Without this the decoder would happily report a stranger's AirPods.
    var pairedModels: Set<UInt16> = []

    /// Readings for paired models only, as name-less values keyed by model.
    @Published private(set) var continuity: [UInt16: ContinuityReading] = [:]

    /// How close a broadcaster has to be before its reading is trusted. Anything
    /// fainter is more likely to be someone else's.
    private static let minimumRSSI = -70

    private var knownStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Volt", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("known-bluetooth-devices.json")
    }

    private override init() { super.init() }

    func start() {
        guard central == nil else { return }
        loadKnown()
        // The power alert is suppressed: Volt should not nag about Bluetooth being off.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])

        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 3
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        central?.stopScan()
        for peripheral in peripherals.values { central?.cancelPeripheralConnection(peripheral) }
        peripherals.removeAll()
        levels.removeAll()
        batteries = []
    }

    func refresh() { poll() }

    /// What the monitor is currently tracking, for the debug log.
    var trackedSummary: [String] {
        peripherals.values.map { peripheral in
            let state: String
            switch peripheral.state {
            case .connected: state = "connected"
            case .connecting: state = "connecting"
            case .disconnecting: state = "disconnecting"
            default: state = "disconnected"
            }
            let level = levels[peripheral.identifier].map { "\($0.percent)%" } ?? "no level"
            return "\(peripheral.name ?? "unnamed") [\(state)] \(level)"
        }
    }

    var knownCount: Int { knownIdentifiers.count }

    // MARK: - Discovery

    /// Three ways in, because no single one is reliable.
    ///
    /// A phone that happens to be BLE-connected to the Mac shows up through
    /// `retrieveConnectedPeripherals`, but that connection comes and goes with
    /// Continuity, so it is often empty even with the phone sitting right there.
    /// Devices seen before are retrieved by identifier and given a connect request
    /// that stays pending until they are reachable. Anything else has to be scanned
    /// for — and the scan cannot filter on the battery service, because an iPhone
    /// advertises Apple's own payload and never mentions 0x180F. So the scan is
    /// unfiltered and candidates are picked from the advertisement instead.
    private func poll() {
        guard let central, central.state == .poweredOn else { return }

        for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.batteryService]) {
            adopt(peripheral)
        }

        if !knownIdentifiers.isEmpty {
            for peripheral in central.retrievePeripherals(withIdentifiers: Array(knownIdentifiers)) {
                adopt(peripheral)
            }
        }

        for peripheral in peripherals.values where peripheral.state == .connected {
            readLevel(from: peripheral)
        }

        if !central.isScanning {
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            // Scanning continuously costs power; a window each cycle is enough.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.central?.stopScan()
            }
        }
    }

    /// Only connect to something worth connecting to: a device already known to answer,
    /// one that advertises the battery service outright, or one whose name says it is
    /// the user's phone or tablet. Connecting to every stray beacon in range would be
    /// slow and rude.
    private func isCandidate(_ peripheral: CBPeripheral, advertisement: [String: Any]) -> Bool {
        if knownIdentifiers.contains(peripheral.identifier) { return true }

        if let services = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           services.contains(Self.batteryService) {
            return true
        }

        let name = ((advertisement[CBAdvertisementDataLocalNameKey] as? String)
                    ?? peripheral.name ?? "").lowercased()
        guard !name.isEmpty else { return false }
        // AirPods are worth a try: macOS stops reporting their level through the
        // Bluetooth report once they are connected, so if they happen to expose the
        // standard battery service it is the only live figure available.
        return ["iphone", "ipad", "ipod", "airpods"].contains { name.contains($0) }
    }

    private func adopt(_ peripheral: CBPeripheral) {
        if peripherals[peripheral.identifier] == nil {
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
        }
        if peripheral.state != .connected {
            // Without a timeout this request simply waits until the device is reachable.
            central?.connect(peripheral, options: nil)
        } else if peripheral.services == nil {
            peripheral.discoverServices([Self.batteryService])
        }
    }

    // MARK: - Remembering devices

    private func loadKnown() {
        guard let data = try? Data(contentsOf: knownStoreURL),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return }
        knownIdentifiers = Set(ids)
    }

    private func remember(_ identifier: UUID) {
        guard knownIdentifiers.insert(identifier).inserted else { return }
        guard let data = try? JSONEncoder().encode(Array(knownIdentifiers)) else { return }
        try? data.write(to: knownStoreURL, options: .atomic)
    }

    private func readLevel(from peripheral: CBPeripheral) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService })
        else {
            peripheral.discoverServices([Self.batteryService])
            return
        }
        guard let characteristic = service.characteristics?
            .first(where: { $0.uuid == Self.batteryLevel })
        else {
            peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    private func publish() {
        let updated = levels.values.sorted {
            if $0.isStale != $1.isStale { return !$0.isStale }
            return $0.percent < $1.percent
        }
        guard updated != batteries else { return }
        batteries = updated
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEBatteryMonitor: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        if central.state == .poweredOn {
            poll()
        } else {
            for key in levels.keys { levels[key]?.isStale = true }
            publish()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        captureAdvertisement(peripheral, advertisementData, rssi: RSSI)
        guard isCandidate(peripheral, advertisement: advertisementData) else { return }
        adopt(peripheral)
    }

    private func captureAdvertisement(_ peripheral: CBPeripheral,
                                      _ advertisement: [String: Any], rssi: NSNumber) {
        guard let data = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data,
              let reading = ContinuityDecoder.decode(manufacturerData: data,
                                                     rssi: rssi.intValue) else { return }

        guard pairedModels.contains(reading.model),
              reading.rssi >= Self.minimumRSSI else { return }

        // Keep the closest broadcaster of each model.
        if let existing = continuityByModel[reading.model],
           existing.rssi > reading.rssi,
           Date().timeIntervalSince(existing.seen) < 60 {
            return
        }
        continuityByModel[reading.model] = reading
        continuity = continuityByModel
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        // Keep a device that has answered before; it is probably just out of reach.
        if !knownIdentifiers.contains(peripheral.identifier) {
            peripherals.removeValue(forKey: peripheral.identifier)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        levels[peripheral.identifier]?.isStale = true
        publish()

        if knownIdentifiers.contains(peripheral.identifier) {
            // Ask for it back; the request waits until the device returns.
            central.connect(peripheral, options: nil)
        } else {
            peripherals.removeValue(forKey: peripheral.identifier)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEBatteryMonitor: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService })
        else { return }
        peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil,
              let characteristic = service.characteristics?
                .first(where: { $0.uuid == Self.batteryLevel }) else { return }

        peripheral.readValue(for: characteristic)
        // Most devices push updates, which spares us most of the polling.
        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil,
              characteristic.uuid == Self.batteryLevel,
              let data = characteristic.value,
              let raw = data.first else { return }

        let name = peripheral.name ?? "Bluetooth Device"
        remember(peripheral.identifier)
        levels[peripheral.identifier] = BLEBattery(id: peripheral.identifier,
                                                   name: name,
                                                   percent: Int(min(raw, 100)),
                                                   updated: Date(),
                                                   isStale: false)
        publish()
    }
}
