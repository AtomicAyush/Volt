import Foundation
import Combine

/// Battery for an iPhone or iPad attached to this Mac.
struct IOSDevice: Equatable {
    let udid: String
    let name: String
    let productType: String     // e.g. "iPhone17,2"
    let percent: Int
    let isCharging: Bool

    var kind: DeviceBattery.Kind {
        if productType.hasPrefix("iPad") { return .tablet }
        if productType.hasPrefix("Watch") { return .watch }
        return .phone
    }
}

/// Reads iPhone / iPad battery over the cable.
///
/// Bluetooth does not carry it: macOS publishes only an address and signal strength
/// for an iPhone, so no app can show its battery over the air. The level is available
/// through `MobileDevice.framework`, the same private framework Finder and Xcode use,
/// and only while the device is plugged in and trusted. Every call is resolved with
/// `dlsym` and every step is guarded, so a missing or changed framework degrades to
/// "no devices" rather than failing.
/// The callback takes `AMDeviceNotificationCallbackInfo *`, which is
/// `{ AMDeviceRef device; uint32_t message; }`. A Swift struct is not representable
/// in C, so the parameter is a raw pointer and the two fields are loaded by offset.
private typealias AMNotificationCallback =
    @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

private enum AMCallbackInfo {
    static let deviceOffset = 0
    static let messageOffset = MemoryLayout<OpaquePointer?>.stride
}

final class IOSDeviceMonitor: ObservableObject {
    static let shared = IOSDeviceMonitor()

    @Published private(set) var devices: [IOSDevice] = []

    /// True when the framework loaded; false means the cable path is unavailable.
    private(set) var isAvailable = false

    private typealias DeviceRef = OpaquePointer

    private typealias SubscribeFn = @convention(c) (
        AMNotificationCallback, UInt32, UInt32,
        UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> Int32
    private typealias DeviceFn = @convention(c) (DeviceRef?) -> Int32
    private typealias CopyValueFn = @convention(c) (DeviceRef?, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias CopyIdentifierFn = @convention(c) (DeviceRef?) -> Unmanaged<CFString>?

    private var handle: UnsafeMutableRawPointer?
    private var subscribe: SubscribeFn?
    private var connect: DeviceFn?
    private var disconnect: DeviceFn?
    private var validatePairing: DeviceFn?
    private var startSession: DeviceFn?
    private var stopSession: DeviceFn?
    private var copyValue: CopyValueFn?
    private var copyIdentifier: CopyIdentifierFn?

    /// Devices currently attached, keyed by UDID.
    private var attached: [String: DeviceRef] = [:]
    private var timer: Timer?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard load() else { return }
        isAvailable = true

        var token: UnsafeMutableRawPointer?
        _ = subscribe?({ info, _ in
            guard let info else { return }
            let device = info.load(fromByteOffset: AMCallbackInfo.deviceOffset,
                                   as: OpaquePointer?.self)
            let message = info.load(fromByteOffset: AMCallbackInfo.messageOffset,
                                    as: UInt32.self)
            guard let device else { return }
            // 1 = attached, 2 = detached.
            switch message {
            case 1: IOSDeviceMonitor.shared.handleAttach(device)
            case 2: IOSDeviceMonitor.shared.handleDetach(device)
            default: break
            }
        }, 0, 0, nil, &token)

        // Battery moves slowly; re-read the attached devices now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshAttached()
        }
        timer?.tolerance = 10
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() { refreshAttached() }

    // MARK: - Framework

    private func load() -> Bool {
        let paths = [
            "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
            "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
        ]
        for path in paths {
            if let h = dlopen(path, RTLD_LAZY) { handle = h; break }
        }
        guard let handle else { return false }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        subscribe = symbol("AMDeviceNotificationSubscribe", as: SubscribeFn.self)
        connect = symbol("AMDeviceConnect", as: DeviceFn.self)
        disconnect = symbol("AMDeviceDisconnect", as: DeviceFn.self)
        validatePairing = symbol("AMDeviceValidatePairing", as: DeviceFn.self)
        startSession = symbol("AMDeviceStartSession", as: DeviceFn.self)
        stopSession = symbol("AMDeviceStopSession", as: DeviceFn.self)
        copyValue = symbol("AMDeviceCopyValue", as: CopyValueFn.self)
        copyIdentifier = symbol("AMDeviceCopyDeviceIdentifier", as: CopyIdentifierFn.self)

        return subscribe != nil && connect != nil && copyValue != nil
            && startSession != nil && validatePairing != nil
    }

    // MARK: - Device events

    private func handleAttach(_ device: DeviceRef) {
        guard let udid = identifier(of: device) else { return }
        DispatchQueue.main.async {
            self.attached[udid] = device
            self.refreshAttached()
        }
    }

    private func handleDetach(_ device: DeviceRef) {
        guard let udid = identifier(of: device) else { return }
        DispatchQueue.main.async {
            self.attached.removeValue(forKey: udid)
            self.devices.removeAll { $0.udid == udid }
        }
    }

    private func identifier(of device: DeviceRef) -> String? {
        copyIdentifier?(device)?.takeRetainedValue() as String?
    }

    private func refreshAttached() {
        var found: [IOSDevice] = []
        for (udid, device) in attached {
            if let reading = read(device, udid: udid) { found.append(reading) }
        }
        let sorted = found.sorted { $0.percent < $1.percent }
        guard sorted != devices else { return }
        devices = sorted
    }

    /// Opens a session, reads the battery domain, and always tears the session down.
    private func read(_ device: DeviceRef, udid: String) -> IOSDevice? {
        guard let connect, let copyValue, let startSession,
              let validatePairing else { return nil }

        guard connect(device) == 0 else { return nil }
        defer { _ = disconnect?(device) }

        // An untrusted device answers here; that is expected, not an error.
        guard validatePairing(device) == 0 else { return nil }
        guard startSession(device) == 0 else { return nil }
        defer { _ = stopSession?(device) }

        func value(_ domain: String?, _ key: String) -> CFTypeRef? {
            copyValue(device, domain as CFString?, key as CFString).map { $0.takeRetainedValue() }
        }

        let battery = "com.apple.mobile.battery"
        guard let raw = value(battery, "BatteryCurrentCapacity") as? Int else { return nil }

        let name = (value(nil, "DeviceName") as? String) ?? "iOS Device"
        let product = (value(nil, "ProductType") as? String) ?? "iPhone"
        let charging = (value(battery, "BatteryIsCharging") as? Bool) ?? false

        return IOSDevice(udid: udid, name: name, productType: product,
                         percent: max(0, min(100, raw)), isCharging: charging)
    }
}
