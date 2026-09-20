import Foundation
import CoreBluetooth
import Combine

/// A battery level read over Bluetooth Low Energy.
struct BLEBattery: Identifiable, Equatable {
    let id: UUID
    let name: String
    let percent: Int
    let updated: Date
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

    private override init() { super.init() }

    func start() {
        guard central == nil else { return }
        // The power alert is suppressed: Volt should not nag about Bluetooth being off.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 5
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

    // MARK: - Discovery

    /// Two ways in: devices already connected to the system (the usual case for a
    /// nearby iPhone), and a scan for anything advertising the service.
    private func poll() {
        guard let central, central.state == .poweredOn else { return }

        for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.batteryService]) {
            adopt(peripheral)
        }

        for peripheral in peripherals.values where peripheral.state == .connected {
            readLevel(from: peripheral)
        }

        if !central.isScanning {
            central.scanForPeripherals(withServices: [Self.batteryService],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            // Scanning continuously costs power; a short window each cycle is enough.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.central?.stopScan()
            }
        }
    }

    private func adopt(_ peripheral: CBPeripheral) {
        if peripherals[peripheral.identifier] == nil {
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
        }
        if peripheral.state != .connected {
            central?.connect(peripheral, options: nil)
        } else if peripheral.services == nil {
            peripheral.discoverServices([Self.batteryService])
        }
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
        let updated = levels.values.sorted { $0.percent < $1.percent }
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
            levels.removeAll()
            publish()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        adopt(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        peripherals.removeValue(forKey: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        levels.removeValue(forKey: peripheral.identifier)
        publish()
        // The device may simply have wandered off; try again on the next sweep.
        peripherals.removeValue(forKey: peripheral.identifier)
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
        levels[peripheral.identifier] = BLEBattery(id: peripheral.identifier,
                                                   name: name,
                                                   percent: Int(min(raw, 100)),
                                                   updated: Date())
        publish()
    }
}
