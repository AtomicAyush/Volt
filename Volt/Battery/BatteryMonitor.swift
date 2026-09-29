import Foundation
import IOKit
import IOKit.ps
import Combine
import AppKit

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
    private var cancellables = Set<AnyCancellable>()
    private var lastProfilerRefresh: Date = .distantPast
    private var interestNotification: io_object_t = IO_OBJECT_NULL
    private var notifyPort: IONotificationPortRef?

    private init() {}

    func start() {
        refresh()
        installPowerSourceNotification()
        installBatteryInterestNotification()

        // Low Power Mode and waking from sleep change the draw at once; let the time
        // estimate follow quickly. Duplicates are removed before the current value is
        // dropped, so only a real change counts.
        LowPowerMode.shared.$isEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.drawChanged() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.drawChanged() }
            .store(in: &cancellables)

        // The SMC refreshes about once a second, so that is the cadence worth
        // sampling at. The interest notification above still catches registry
        // republishes as they happen.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.2
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
        applyFastChargingState(to: &new)
        if new.isPluggedIn != snapshot.isPluggedIn { drawChanged() }
        estimateTime(for: &new)
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

        // macOS 27 restructured the battery. What was one flat entry is now a tree —
        // battery, pack, banks, cells — and many figures moved: capacities into the
        // entry's BatteryData, and temperature and the raw capacities onto the child
        // AppleSmartBatteryPack. Each key is looked for in the old place first, so
        // macOS 26 reads exactly as before, then in the new ones.
        let batteryData = props["BatteryData"] as? [String: Any] ?? [:]
        let packData = Self.packBatteryData()
        func int(_ key: String) -> Int? {
            (props[key] as? Int) ?? (batteryData[key] as? Int) ?? (packData[key] as? Int)
        }
        func bool(_ key: String) -> Bool { (props[key] as? Bool) ?? false }

        s.isPresent = bool("BatteryInstalled")
        s.percentage = int("CurrentCapacity") ?? 0
        s.isCharging = bool("IsCharging")
        s.isPluggedIn = bool("ExternalConnected")
        s.isFullyCharged = bool("FullyCharged")

        s.cycleCount = int("CycleCount") ?? 0
        s.designCapacity = int("DesignCapacity") ?? 0
        s.nominalChargeCapacity = int("NominalChargeCapacity") ?? 0
        s.rawMaxCapacity = int("AppleRawMaxCapacity") ?? int("FullChargeCapacity") ?? 0
        s.rawCurrentCapacity = int("AppleRawCurrentCapacity") ?? int("RemainingCapacity") ?? 0

        // Temperature arrives in hundredths of a degree Celsius.
        if let t = int("Temperature"), t > 0 {
            s.temperatureC = Double(t) / 100
        } else if let sensor = SMC.shared.float("TB0T"), sensor > 0, sensor < 100 {
            // Last resort: the pack's own temperature sensor.
            s.temperatureC = sensor
        }
        if let v = int("Voltage") { s.voltage = Double(v) / 1000 }
        if let a = int("Amperage") { s.amperage = Double(a) / 1000 }

        let raw = s.isPluggedIn ? int("AvgTimeToFull") : int("AvgTimeToEmpty")
        s.minutesRemaining = Self.sanitize(raw)

        // The negotiated wattage has lived in AdapterDetails; the raw adapter list is
        // the fallback in case it moves the way the battery figures did.
        let rawAdapter = (props["AppleRawAdapterDetails"] as? [[String: Any]])?.first
        if s.adapterWatts == nil, let watts = rawAdapter?["Watts"] as? Int, watts > 0 {
            s.adapterWatts = watts
        }
        if let adapter = props["AdapterDetails"] as? [String: Any] {
            s.adapterWatts = (adapter["Watts"] as? Int) ?? s.adapterWatts
            s.adapterName = (adapter["Name"] as? String) ?? (adapter["Description"] as? String)
        }

        // The gauge publishes both sides of the power split, which is what makes a
        // flow diagram possible: what the adapter is delivering, and what the Mac is
        // drawing. The rest goes into the battery. These are slow fallbacks; the SMC
        // below supplies the live figures.
        if let data = props["BatteryData"] as? [String: Any] {
            s.adapterPower = data["AdapterPower"] as? Double
            s.systemPower = data["SystemPower"] as? Double
        }
        // macOS 27 dropped both of those and reports the system draw here, in mW.
        if s.systemPower == nil,
           let telemetry = props["PowerTelemetryData"] as? [String: Any],
           let milliwatts = telemetry["SystemLoad"] as? Int, milliwatts > 0 {
            s.systemPower = Double(milliwatts) / 1000
        }

        applySMC(to: &s)
        applyPortOutputs(to: &s)
        return s
    }

    /// Overlays the measurements the SMC carries, which refresh about every second.
    /// The registry's own copies lag by many seconds and repeat in between, so the
    /// readout looked frozen next to anything reading the controller directly.
    private func applySMC(to s: inout BatterySnapshot) {
        let smc = SMC.shared
        guard smc.isAvailable else { return }

        if let milliamps = smc.int16("B0AC") { s.amperage = Double(milliamps) / 1000 }
        if let millivolts = smc.uint16("B0AV"), millivolts > 1000 {
            s.voltage = Double(millivolts) / 1000
        }
        // PDTR is what the adapter is putting in. PSTR is not used for the system figure:
        // on AC it is the same power-in-less-battery sum `load` works out, but a tick
        // behind, and on battery it bears no relation to what is leaving the pack.
        if let adapterIn = smc.float("PDTR"), adapterIn > 0 { s.adapterPower = adapterIn }
        if let batteryPower = smc.float("PPBR") { s.batteryPower = batteryPower }
    }

    /// What each port is supplying, and to what. The watts are read every second, and so is
    /// the device on the port; its name is worked out again every half minute, or every
    /// five seconds until its own name turns up — the Bluetooth scan that name comes from
    /// takes a few seconds after launch.
    private var portNames: [Int: (identity: PortPower.Identity?, name: String, symbol: String,
                                  isOwnName: Bool, looked: Date)] = [:]

    private func applyPortOutputs(to s: inout BatterySnapshot) {
        let outputs = PortPower.outputs()
        let active = Set(outputs.map(\.port))
        portNames = portNames.filter { active.contains($0.key) }

        s.portOutputs = outputs.map { port, watts in
            // Identified every time — a fraction of a millisecond — so a device swapped on
            // the same port is noticed at once; only the naming is cached.
            let identity = PortPower.identify(port: port)
            if let known = portNames[port], known.identity == identity,
               Date().timeIntervalSince(known.looked) < (known.isOwnName ? 30 : 5) {
                return PortOutput(port: port, watts: watts, name: known.name, symbol: known.symbol,
                                  serial: identity?.serial)
            }
            let (name, symbol, isOwnName) = Self.describe(identity)
            portNames[port] = (identity, name, symbol, isOwnName, Date())
            return PortOutput(port: port, watts: watts, name: name, symbol: symbol, serial: identity?.serial)
        }
    }

    /// The paired device's own name ("Ayush's AirPods Max") when its serial number is
    /// known over Bluetooth or the cable, else the name the USB device gives. The flag
    /// says which it is.
    private static func describe(_ identity: PortPower.Identity?) -> (String, String, Bool) {
        if let serial = identity?.serial, !serial.isEmpty {
            if let paired = DeviceMonitor.shared.device(serial: serial) {
                return (paired.name, paired.kind.symbol, true)
            }
            let flat = serial.replacingOccurrences(of: "-", with: "").uppercased()
            if let phone = IOSDeviceMonitor.shared.devices.first(where: {
                $0.udid.replacingOccurrences(of: "-", with: "").uppercased() == flat
            }) {
                return (phone.name, phone.kind.symbol, true)
            }
        }
        if var name = identity?.usbName, !name.isEmpty {
            // "AirPods Max USB Audio" is the headphones.
            for suffix in [" USB Audio", " USB"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            let kind = DeviceBattery.Kind.from(minorType: nil, name: name)
            return (name, kind == .other ? "cable.connector" : kind.symbol, false)
        }
        return ("USB-C accessory", "cable.connector", false)
    }

    /// The gauge reports a "still working it out" value in several ways: 65535, -1,
    /// or — when current momentarily reads zero — an estimate of hundreds of hours.
    /// Anything beyond a day is not a real reading.
    private static func sanitize(_ minutes: Int?) -> Int? {
        guard let minutes, minutes > 0, minutes <= 24 * 60 else { return nil }
        return minutes
    }

    /// The registry's charging flag can take many seconds to flip after plugging in — the
    /// alert fired at once but the panel kept saying "Plugged in" at +0.5 W. A pack taking
    /// real current while on AC is charging, whatever the flag says yet.
    private func applyFastChargingState(to s: inout BatterySnapshot) {
        if s.isPluggedIn, s.amperage > 0.1 { s.isCharging = true }
        if !s.isPluggedIn { s.isCharging = false }
    }

    /// The live current, smoothed, and when the draw last changed character — on the
    /// monotonic clock, since a wall-clock step would otherwise throw the average out.
    private var smoothedAmperage: Double?
    private var lastSmoothed: TimeInterval?
    private var drawChangedAt = ProcessInfo.processInfo.systemUptime

    /// Something that changes how much power the Mac uses just happened — Low Power Mode,
    /// plugging in or out, waking from sleep — so the average starts over.
    func drawChanged() {
        drawChangedAt = ProcessInfo.processInfo.systemUptime
        smoothedAmperage = nil
    }

    /// Time left on battery comes from Volt's own reading: the charge left over the live
    /// current, averaged. The gauge's own figure only moves when its registry entry
    /// republishes, about once a minute, and then takes the current of that moment, so
    /// after Low Power Mode went on it sat unchanged for most of a minute and then jumped
    /// about — 63, 47, 55, 46 minutes in two — while the draw had already halved.
    ///
    /// After a change the average is a plain mean of every reading since, so it follows
    /// within seconds and one odd reading soon counts for little; from a minute and a half
    /// on it becomes a moving average over that long, so it holds steady.
    ///
    /// Charging keeps the gauge's estimate, which knows how charging slows near full; this
    /// only fills in when it has none.
    private func estimateTime(for s: inout BatterySnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        let amps = s.amperage
        // A current near zero — plugged in and full, or held at a charge limit — says
        // nothing about what comes next, so the next real reading starts afresh.
        if let previous = smoothedAmperage, abs(previous) > 0.05, (previous > 0) == (amps > 0) {
            let elapsed = min(5, max(0, lastSmoothed.map { now - $0 } ?? 1))
            let span = min(90, 1 + (now - drawChangedAt))
            smoothedAmperage = previous + (amps - previous) * (1 - exp(-elapsed / span))
        } else {
            if smoothedAmperage != nil { drawChangedAt = now }
            smoothedAmperage = amps
        }
        lastSmoothed = now

        guard let current = smoothedAmperage, abs(current) > 0.05, s.rawMaxCapacity > 0 else { return }
        if s.isDischarging, current < 0, s.rawCurrentCapacity > 0 {
            let minutes = Double(s.rawCurrentCapacity) / (-current * 1000) * 60
            s.minutesRemaining = Self.sanitize(Int(minutes.rounded()))
        } else if s.minutesRemaining == nil, s.isCharging, current > 0 {
            let minutes = Double(max(0, s.rawMaxCapacity - s.rawCurrentCapacity)) / (current * 1000) * 60
            s.minutesRemaining = Self.sanitize(Int(minutes.rounded()))
        }
    }

    /// The BatteryData of the AppleSmartBatteryPack child entry, where macOS 27 keeps
    /// temperature and the raw capacities. Empty on systems without it.
    private static func packBatteryData() -> [String: Any] {
        let pack = IOServiceGetMatchingService(kIOMainPortDefault,
                                               IOServiceMatching("AppleSmartBatteryPack"))
        guard pack != IO_OBJECT_NULL else { return [:] }
        defer { IOObjectRelease(pack) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(pack, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return [:] }
        return props["BatteryData"] as? [String: Any] ?? [:]
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
            // IOPowerSources flips on the change notification itself, well ahead of the
            // registry, so it decides plugged in and charging.
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                s.isPluggedIn = state == kIOPSACPowerValue
            }
            if let charging = desc[kIOPSIsChargingKey] as? Bool, charging {
                s.isCharging = true
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
