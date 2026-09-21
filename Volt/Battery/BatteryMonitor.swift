import Foundation
import IOKit
import IOKit.ps
import Combine

/// Reads the internal battery from IOKit and republishes it whenever it changes.
///
/// Two sources drive updates: `IOPSNotificationCreateRunLoopSource` fires the moment
/// macOS notices a percentage or power-source change, and a slow timer keeps the
/// live values (temperature, amperage, watts) moving between those events.
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    @Published private(set) var snapshot = BatterySnapshot()

    /// Emits the previous and new snapshot on every change, for the alert engine.
    let transitions = PassthroughSubject<(old: BatterySnapshot, new: BatterySnapshot), Never>()

    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?
    private var lastProfilerRefresh: Date = .distantPast
    private var interestNotification: io_object_t = IO_OBJECT_NULL
    private var notifyPort: IONotificationPortRef?

    private init() {}

    func start() {
        refresh()
        installPowerSourceNotification()
        installBatteryInterestNotification()

        // The registry republishes on its own schedule — sometimes seconds apart,
        // sometimes not. The interest notification above catches each republish as it
        // happens; this is only a floor under it.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.5
        refreshSystemProfilerFacts()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            runLoopSource = nil
        }
        if interestNotification != IO_OBJECT_NULL {
            IOObjectRelease(interestNotification)
            interestNotification = IO_OBJECT_NULL
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
    }

    /// Fires whenever AppleSmartBattery republishes its properties, which is when new
    /// current and voltage readings actually land. Polling alone either lags behind
    /// this or samples the same values repeatedly.
    private func installBatteryInterestNotification() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { ctx, _, _, _ in
            guard let ctx else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.refresh()
        }, context, &interestNotification)
    }

    // MARK: - Reading

    func refresh() {
        var new = readIOKit()
        // Carry forward the facts that only system_profiler knows about.
        new.condition = snapshot.condition
        new.appleMaxCapacity = snapshot.appleMaxCapacity
        applyPowerSourceInfo(to: &new)
        new.updated = Date()

        guard new != snapshot else { return }
        let old = snapshot
        snapshot = new
        transitions.send((old: old, new: new))

        // Condition and Apple's capacity figure change on the order of days.
        if Date().timeIntervalSince(lastProfilerRefresh) > 900 {
            refreshSystemProfilerFacts()
        }
    }

    private func readIOKit() -> BatterySnapshot {
        var s = BatterySnapshot()
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return s }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return s }

        func int(_ key: String) -> Int? { props[key] as? Int }
        func bool(_ key: String) -> Bool { (props[key] as? Bool) ?? false }

        s.isPresent = bool("BatteryInstalled")
        s.percentage = int("CurrentCapacity") ?? 0
        s.isCharging = bool("IsCharging")
        s.isPluggedIn = bool("ExternalConnected")
        s.isFullyCharged = bool("FullyCharged")

        s.cycleCount = int("CycleCount") ?? 0
        s.designCapacity = int("DesignCapacity") ?? 0
        s.nominalChargeCapacity = int("NominalChargeCapacity") ?? 0
        s.rawMaxCapacity = int("AppleRawMaxCapacity") ?? 0
        s.rawCurrentCapacity = int("AppleRawCurrentCapacity") ?? 0

        // Temperature arrives in hundredths of a degree Celsius.
        if let t = int("Temperature") { s.temperatureC = Double(t) / 100 }
        if let v = int("Voltage") { s.voltage = Double(v) / 1000 }
        if let a = int("Amperage") { s.amperage = Double(a) / 1000 }

        let raw = s.isPluggedIn ? int("AvgTimeToFull") : int("AvgTimeToEmpty")
        s.minutesRemaining = Self.sanitize(raw)

        if let adapter = props["AdapterDetails"] as? [String: Any] {
            s.adapterWatts = adapter["Watts"] as? Int
            s.adapterName = (adapter["Name"] as? String) ?? (adapter["Description"] as? String)
        }

        // The gauge publishes both sides of the power split, which is what makes a
        // flow diagram possible: what the adapter is delivering, and what the Mac is
        // drawing. The rest goes into the battery.
        if let data = props["BatteryData"] as? [String: Any] {
            s.adapterPower = data["AdapterPower"] as? Double
            s.systemPower = data["SystemPower"] as? Double
        }
        return s
    }

    /// The gauge reports a "still working it out" value in several ways: 65535, -1,
    /// or — when current momentarily reads zero — an estimate of hundreds of hours.
    /// Anything beyond a day is not a real reading.
    private static func sanitize(_ minutes: Int?) -> Int? {
        guard let minutes, minutes > 0, minutes <= 24 * 60 else { return nil }
        return minutes
    }

    /// IOPowerSources knows a few things the raw registry does not, and agrees with `pmset`.
    private func applyPowerSourceInfo(to s: inout BatterySnapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            guard (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            if let cur = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                s.percentage = Int((Double(cur) / Double(max) * 100).rounded())
            }
            if let health = desc[kIOPSBatteryHealthKey] as? String, s.condition == nil {
                s.condition = health
            }
            if s.minutesRemaining == nil {
                let key = s.isPluggedIn ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
                s.minutesRemaining = Self.sanitize(desc[key] as? Int)
            }
        }
    }

    /// `Condition` and `Maximum Capacity` as System Settings reports them. Slow, so it
    /// runs off the main thread and only every 15 minutes.
    private func refreshSystemProfilerFacts() {
        lastProfilerRefresh = Date()
        DispatchQueue.global(qos: .utility).async {
            let text = Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType"]) ?? ""
            var condition: String?
            var maxCapacity: Int?
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Condition:") {
                    condition = trimmed.replacingOccurrences(of: "Condition:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Maximum Capacity:") {
                    maxCapacity = Int(trimmed.filter(\.isNumber))
                }
            }
            DispatchQueue.main.async {
                if let condition { self.snapshot.condition = condition }
                if let maxCapacity { self.snapshot.appleMaxCapacity = maxCapacity }
            }
        }
    }

    // MARK: - Change notifications

    private func installPowerSourceNotification() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { monitor.refresh() }
        }, context)?.takeRetainedValue() else { return }

        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }
}
