import Foundation

/// One point-in-time reading of the internal battery.
struct BatterySnapshot: Equatable {
    var isPresent: Bool = false

    /// 0...100, the percentage macOS shows in the menu bar.
    var percentage: Int = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var isFullyCharged: Bool = false

    var cycleCount: Int = 0
    var designCapacity: Int = 0          // mAh
    var nominalChargeCapacity: Int = 0   // mAh, what the pack holds today
    var rawMaxCapacity: Int = 0          // mAh, gauge's learned full charge
    var rawCurrentCapacity: Int = 0      // mAh

    var temperatureC: Double = 0         // battery pack
    var voltage: Double = 0              // volts
    var amperage: Double = 0             // amps, negative while discharging

    /// Minutes until empty (discharging) or full (charging). nil while calculating.
    var minutesRemaining: Int?

    var adapterWatts: Int?
    var adapterName: String?

    /// "Normal", "Service Recommended", ... as reported by macOS.
    var condition: String?
    /// The "Maximum Capacity" figure from System Settings, when known.
    var appleMaxCapacity: Int?

    var updated: Date = .distantPast

    /// Health computed from the gauge: how much of the design capacity is left.
    var healthPercent: Double? {
        guard designCapacity > 0, nominalChargeCapacity > 0 else { return nil }
        return Double(nominalChargeCapacity) / Double(designCapacity) * 100
    }

    /// Instantaneous power flow in watts. Positive = charging, negative = draining.
    var watts: Double { voltage * amperage }

    var isDischarging: Bool { isPresent && !isPluggedIn }

    /// "3h 40min until empty" / "42min until full", for the alert subtitle.
    var untilText: String {
        guard let m = minutesRemaining, m > 0 else {
            if isFullyCharged && isPluggedIn { return "Fully charged" }
            return isPluggedIn ? "Estimating time to full" : "Estimating time remaining"
        }
        let h = m / 60, mm = m % 60
        let span = h > 0 ? "\(h)h \(mm)min" : "\(mm)min"
        return isPluggedIn ? "\(span) until full" : "\(span) until empty"
    }

    var timeRemainingText: String {
        guard let m = minutesRemaining, m > 0 else {
            if isFullyCharged && isPluggedIn { return "Fully charged" }
            return isPluggedIn ? "Calculating…" : "Calculating…"
        }
        let h = m / 60, mm = m % 60
        let span = h > 0 ? "\(h)h \(mm)m" : "\(mm)m"
        return isPluggedIn ? "\(span) to full" : "\(span) left"
    }
}
