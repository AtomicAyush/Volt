import Foundation
import CoreBluetooth

/// Publishes the watch battery as a Bluetooth value.
///
/// The value is served dynamically — read on request rather than baked into the service —
/// so it is always the latest reading, and centrals that subscribe are notified when it
/// changes. The app declares the bluetooth-peripheral background mode, so iOS keeps
/// serving it, and restores the service after relaunching the app, while it is not in
/// the foreground.
final class BatteryPeripheral: NSObject, ObservableObject {
    static let shared = BatteryPeripheral()

    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var isPublishing = false
    @Published private(set) var subscribers = 0

    private var manager: CBPeripheralManager!
    private var characteristic: CBMutableCharacteristic?
    private var payload: Data?

    private override init() {
        super.init()
        manager = CBPeripheralManager(
            delegate: self, queue: .main,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "volt.watch.battery"]
        )
    }

    func update(with reading: WatchReading) {
        payload = WatchBatteryPayload.encode(percent: reading.percent,
                                             charging: reading.charging,
                                             full: reading.full,
                                             reportedAt: reading.reportedAt)
        if let characteristic, let payload {
            manager.updateValue(payload, for: characteristic, onSubscribedCentrals: nil)
        }
    }

    private func publish() {
        guard characteristic == nil else { startAdvertising(); return }
        let value = CBMutableCharacteristic(type: WatchBatteryPayload.characteristic,
                                            properties: [.read, .notify],
                                            value: nil,
                                            permissions: [.readable])
        let service = CBMutableService(type: WatchBatteryPayload.service, primary: true)
        service.characteristics = [value]
        characteristic = value
        manager.add(service)
    }

    private func startAdvertising() {
        guard !manager.isAdvertising else { return }
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [WatchBatteryPayload.service]])
    }
}

extension BatteryPeripheral: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        state = peripheral.state
        if peripheral.state == .poweredOn { publish() } else { isPublishing = false }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           willRestoreState dict: [String: Any]) {
        // After iOS relaunches the app, pick the already-registered service back up
        // rather than adding a duplicate.
        let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        for service in services where service.uuid == WatchBatteryPayload.service {
            characteristic = service.characteristics?
                .first { $0.uuid == WatchBatteryPayload.characteristic } as? CBMutableCharacteristic
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService,
                           error: Error?) {
        guard error == nil else { return }
        startAdvertising()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        isPublishing = error == nil
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        guard let payload else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        guard request.offset <= payload.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = payload.subdata(in: request.offset..<payload.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        subscribers += 1
        if let payload, let value = self.characteristic {
            peripheral.updateValue(payload, for: value, onSubscribedCentrals: [central])
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers = max(0, subscribers - 1)
    }
}
