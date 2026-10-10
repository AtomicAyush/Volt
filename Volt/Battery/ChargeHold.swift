import Foundation

/// Why a Mac that is plugged in is not charging.
enum ChargeHold: Equatable {
    /// Full, and topped up only as it drifts down.
    case full
    /// Optimized Battery Charging is holding the charge, to finish before the Mac is
    /// usually unplugged.
    case optimized(limit: Int)
    /// A charge limit is holding the charge.
    case limit(Int)
    /// Above the limit, so the Mac runs on its battery, charger connected, until it is
    /// down to the limit — Optimized Battery Charging does this after a full charge.
    case lowering(to: Int, optimized: Bool)
    /// The charger is not supplying enough, so the battery is making up the rest.
    case chargerTooWeak(watts: Double)
    /// macOS has paused charging for a reason it does not publish.
    case paused

    /// Short form, for the panel's top corner and the menu bar tooltip.
    var short: String {
        switch self {
        case .full: return "Full"
        case .optimized(let limit), .limit(let limit): return "Held at \(limit)%"
        case .lowering(let limit, _): return "Down to \(limit)%"
        case .chargerTooWeak: return "Weak charger"
        case .paused: return "Paused"
        }
    }

    /// One line saying why.
    var explanation: String {
        switch self {
        case .full:
            return "Fully charged — running on the charger"
        case .optimized(let limit):
            return "Held at \(limit)% by Optimized Battery Charging, to finish before you usually unplug"
        case .limit(let limit):
            return "Held at \(limit)% by a charge limit"
        case .lowering(let limit, let optimized):
            return optimized
                ? "Running on battery down to \(limit)%, where Optimized Battery Charging will hold it"
                : "Running on battery down to the \(limit)% charge limit"
        case .chargerTooWeak(let watts):
            return String(format: "The charger can't keep up — the battery is adding %.0f W", watts)
        case .paused:
            return "macOS has paused charging"
        }
    }
}

/// Reads why charging is on hold.
///
/// Two sources. The battery's `ChargerData.NotChargingReason` is a bit field; in this
/// Mac's power log, 0x400000 came only with a full battery on the charger, and
/// 0x1000000 only while it sat at 80–90% on the charger. And powerd keeps the charge
/// policy it is applying in /Library/Preferences/com.apple.powerd.charging.plist,
/// readable by anyone: a keyed archive of `ChargeCtrlPolicy` objects with a `reason`
/// ("optimizedBatteryCharging") and a `soclimit` (80).
enum ChargeHoldReader {
    private static let noExternalPower = 0x80
    private static let fullyCharged = 0x400000
    private static let heldAtLimit = 0x1000000

    /// - Parameters:
    ///   - settled: the charger has been connected long enough for its handshake to be
    ///     over. Until then the battery reads "not charging" with no meaning yet.
    ///   - drainingOnCharger: how long the battery has been supplying power with the
    ///     charger connected.
    static func hold(notChargingReason: Int?, snapshot s: BatterySnapshot,
                     policy: (reason: String, limit: Int)?,
                     settled: Bool, drainingOnCharger: TimeInterval) -> ChargeHold? {
        guard s.isPresent, s.isPluggedIn else { return nil }
        let bits = notChargingReason ?? 0
        // 0x80: the charger is not seen yet. Every reading on battery has it, and so does
        // the handshake after plugging in; a real hold never does.
        if bits & noExternalPower != 0 { return nil }
        let knownHold = bits & (fullyCharged | heldAtLimit) != 0 || s.isFullyCharged
        guard settled || knownHold else { return nil }

        if let policy, s.percentage < 100 {
            let optimized = policy.reason == "optimizedBatteryCharging"
            if s.percentage > policy.limit { return .lowering(to: policy.limit, optimized: optimized) }
            return optimized ? .optimized(limit: policy.limit) : .limit(policy.limit)
        }
        // The battery has been making up the difference for a minute with nothing holding
        // the charge back: the charger cannot keep up. macOS still says "charging" then,
        // so this comes before that is checked.
        if drainingOnCharger >= 60, !knownHold { return .chargerTooWeak(watts: max(0, -s.watts)) }

        guard !s.isCharging else { return nil }
        if bits & fullyCharged != 0 || s.isFullyCharged || s.percentage >= 100 { return .full }
        if bits & heldAtLimit != 0 { return .limit(s.percentage) }
        return .paused
    }

    /// The charge policy powerd is applying, if any.
    static func activePolicy() -> (reason: String, limit: Int)? {
        let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")
        guard let data = try? Data(contentsOf: url),
              let outer = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let archive = outer["policies"] as? Data,
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(ChargePolicyRecord.self, forClassName: "ChargeCtrlPolicy")
        defer { unarchiver.finishDecoding() }
        let policies = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [ChargePolicyRecord] ?? []
        // A finished policy no longer holds anything back.
        guard let active = policies.first(where: { !$0.terminated && $0.limit > 0 && $0.limit < 100 })
        else { return nil }
        return (active.reason, active.limit)
    }
}

/// Stands in for powerd's `ChargeCtrlPolicy` when its archive is read.
final class ChargePolicyRecord: NSObject, NSCoding {
    let reason: String
    let limit: Int
    let terminated: Bool

    init?(coder: NSCoder) {
        reason = coder.decodeObject(forKey: "reason") as? String ?? ""
        limit = coder.decodeInteger(forKey: "soclimit")
        terminated = coder.decodeBool(forKey: "terminated")
    }

    func encode(with coder: NSCoder) {}
}
